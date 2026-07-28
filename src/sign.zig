//! Signing and key custody. **This file never ships to a customer.**
//!
//! It is compiled into a separate static library (`libsigil_sign.a`) that only
//! the `sigil` CLI links. Mecha Validate and Mecha Rotshield link `libsigil.a`,
//! which contains none of this — so a shipped product cannot mint a license
//! because the code to do so is not in the binary. That is a property of the
//! linker, not a rule anyone has to remember.
//!
//! Still pure: no I/O, no clock, no randomness. Seeds, salts and nonces are
//! parameters, which is what makes every test here reproducible.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const argon2 = std.crypto.pwhash.argon2;
const pb = @import("printable_binary");
const core = @import("verify.zig");
const envelope = @import("envelope.zig");

pub const seed_len = Ed25519.KeyPair.seed_length;

pub const KeyPair = struct {
    public_key: [core.public_key_len]u8,
    /// The Ed25519 expanded secret key. Never written to disk in this form and
    /// never leaves the process; the seed is what a keyfile stores.
    secret_key: [Ed25519.SecretKey.encoded_length]u8,
};

pub const SignError = error{
    /// The seed did not yield a usable key. Cryptographically negligible, but
    /// an error rather than an assert because this crosses an FFI boundary.
    BadSeed,
    /// Signing failed on a key that did not come from `keyPairFromSeed`.
    BadSecretKey,
};

/// Derive a keypair from a 32-byte seed. Deterministic by definition: the same
/// seed always yields the same key, which is what lets `sigil keygen` be backed
/// up as 32 bytes and what makes every test in this file reproducible.
pub fn keyPairFromSeed(seed: *const [seed_len]u8) SignError!KeyPair {
    const kp = Ed25519.KeyPair.generateDeterministic(seed.*) catch return SignError.BadSeed;
    return .{
        .public_key = kp.public_key.toBytes(),
        .secret_key = kp.secret_key.toBytes(),
    };
}

/// Sign `payload` exactly as given — no canonicalization, matching the verifier.
///
/// Ed25519 is deterministic (RFC 8032): the same key over the same bytes yields
/// the same 64 bytes on every implementation. Nothing here consumes randomness,
/// so a signature is reproducible from the seed alone.
pub fn signPayload(payload: []const u8, kp: KeyPair) SignError![core.signature_len]u8 {
    const sk = Ed25519.SecretKey.fromBytes(kp.secret_key) catch return SignError.BadSecretKey;
    const pair = Ed25519.KeyPair.fromSecretKey(sk) catch return SignError.BadSecretKey;
    const sig = pair.sign(payload, null) catch return SignError.BadSecretKey;
    return sig.toBytes();
}

/// Sign and package in one step. Caller owns the returned envelope.
pub fn seal(
    allocator: std.mem.Allocator,
    payload: []const u8,
    kp: KeyPair,
) (SignError || envelope.WriteError)![]u8 {
    const sig = try signPayload(payload, kp);
    return envelope.write(allocator, payload, &sig);
}

// ── Keyfile: the secret key at rest ─────────────────────────────────────────
//
// Format (one line, same printable-binary-in-JSON shape as an envelope so the
// same eyes and the same tools work on both):
//
//   {"sigil":"secret-key-v1","kdf":"Argon2id","t":3,"m":65536,"p":1,
//    "salt":"…","nonce":"…","ciphertext":"…","public":"…"}
//
// The KDF parameters, the salt and the public key sit outside the ciphertext,
// so they are bound as AEAD associated data. Without that, an attacker who can
// write to the file could downgrade `t`/`m` to 1 and make an offline attack on
// the passphrase cheap, and the reader would happily go along with it.

pub const salt_len = 16;
pub const nonce_len = XChaCha20Poly1305.nonce_length;
pub const tag_len = XChaCha20Poly1305.tag_length;
pub const keyfile_version = "secret-key-v1";
pub const kdf_name = "Argon2id";

pub const KdfParams = struct {
    /// Time cost, in iterations.
    t: u32,
    /// Memory cost, in KiB.
    m: u32,
    /// Parallelism. Pinned to 1 everywhere: a KDF whose output depends on how
    /// many cores the machine had is a keyfile that stops opening on a
    /// different laptop.
    p: u24,
};

/// 64 MiB and three passes — comfortably above the OWASP argon2id floor
/// (19 MiB, t=2) and still under a second on any machine that will ever run
/// `sigil sign`.
pub const default_kdf_params: KdfParams = .{ .t = 3, .m = 64 * 1024, .p = 1 };

pub const KeyfileError = error{
    /// Not well-formed JSON, or missing/short fields.
    MalformedKeyfile,
    /// `sigil` field names a format this build does not know how to read.
    UnsupportedKeyfileVersion,
    /// The passphrase is wrong, or the file has been altered. These are the
    /// same event to an AEAD, and reporting them separately would be a lie.
    AuthenticationFailed,
    /// KDF parameters outside what argon2 will accept.
    BadKdfParams,
};

const KeyfileWire = struct {
    sigil: []const u8,
    kdf: []const u8,
    t: u32,
    m: u32,
    p: u24,
    salt: []const u8,
    nonce: []const u8,
    ciphertext: []const u8,
    public: []const u8,
};

/// Encrypt `seed` under `passphrase`. `salt` and `nonce` are parameters rather
/// than generated here so this function stays pure and every test is
/// reproducible; the CLI supplies them from the OS CSPRNG.
pub fn wrapKey(
    allocator: std.mem.Allocator,
    seed: *const [seed_len]u8,
    passphrase: []const u8,
    salt: *const [salt_len]u8,
    nonce: *const [nonce_len]u8,
    params: KdfParams,
) (KeyfileError || SignError || std.mem.Allocator.Error || envelope.WriteError)![]u8 {
    const kp = try keyPairFromSeed(seed);

    var key: [XChaCha20Poly1305.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(allocator, &key, passphrase, salt, params);

    var aad_buf: [aad_len]u8 = undefined;
    const aad = buildAad(&aad_buf, params, salt, &kp.public_key);

    var blob: [seed_len + tag_len]u8 = undefined;
    XChaCha20Poly1305.encrypt(
        blob[0..seed_len],
        blob[seed_len..][0..tag_len],
        seed,
        aad,
        nonce.*,
        key,
    );

    const salt_enc = try pb.encode(allocator, salt, .{});
    defer allocator.free(salt_enc);
    const nonce_enc = try pb.encode(allocator, nonce, .{});
    defer allocator.free(nonce_enc);
    const blob_enc = try pb.encode(allocator, &blob, .{});
    defer allocator.free(blob_enc);
    const public_enc = try pb.encode(allocator, &kp.public_key, .{});
    defer allocator.free(public_enc);

    return std.fmt.allocPrint(
        allocator,
        "{{\"sigil\":\"" ++ keyfile_version ++ "\",\"kdf\":\"" ++ kdf_name ++ "\"," ++
            "\"t\":{d},\"m\":{d},\"p\":{d}," ++
            "\"salt\":\"{s}\",\"nonce\":\"{s}\",\"ciphertext\":\"{s}\",\"public\":\"{s}\"}}\n",
        .{ params.t, params.m, params.p, salt_enc, nonce_enc, blob_enc, public_enc },
    );
}

/// Recover the seed from a keyfile. Returns `AuthenticationFailed` for both a
/// wrong passphrase and a tampered file, because to an AEAD those are one event.
pub fn unwrapKey(
    allocator: std.mem.Allocator,
    keyfile_json: []const u8,
    passphrase: []const u8,
) (KeyfileError || std.mem.Allocator.Error)![seed_len]u8 {
    const parsed = try parseKeyfile(allocator, keyfile_json);
    defer parsed.deinit();
    const w = parsed.value;

    var salt: [salt_len]u8 = undefined;
    var nonce: [nonce_len]u8 = undefined;
    var blob: [seed_len + tag_len]u8 = undefined;
    var public_key: [core.public_key_len]u8 = undefined;
    try decodeExact(allocator, w.salt, &salt);
    try decodeExact(allocator, w.nonce, &nonce);
    try decodeExact(allocator, w.ciphertext, &blob);
    try decodeExact(allocator, w.public, &public_key);

    const params: KdfParams = .{ .t = w.t, .m = w.m, .p = w.p };
    var key: [XChaCha20Poly1305.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(allocator, &key, passphrase, &salt, params);

    var aad_buf: [aad_len]u8 = undefined;
    const aad = buildAad(&aad_buf, params, &salt, &public_key);

    var seed: [seed_len]u8 = undefined;
    XChaCha20Poly1305.decrypt(
        &seed,
        blob[0..seed_len],
        blob[seed_len..][0..tag_len].*,
        aad,
        nonce,
        key,
    ) catch return KeyfileError.AuthenticationFailed;
    return seed;
}

/// Read the public key out of a keyfile without the passphrase, so `sigil
/// pubkey` can print the value to embed in a product without touching the
/// secret. The value is unauthenticated on its own — anyone editing the file
/// makes `unwrapKey` fail, which is where it matters.
pub fn keyfilePublicKey(
    allocator: std.mem.Allocator,
    keyfile_json: []const u8,
) (KeyfileError || std.mem.Allocator.Error)![core.public_key_len]u8 {
    const parsed = try parseKeyfile(allocator, keyfile_json);
    defer parsed.deinit();
    var public_key: [core.public_key_len]u8 = undefined;
    try decodeExact(allocator, parsed.value.public, &public_key);
    return public_key;
}

fn parseKeyfile(
    allocator: std.mem.Allocator,
    keyfile_json: []const u8,
) (KeyfileError || std.mem.Allocator.Error)!std.json.Parsed(KeyfileWire) {
    const parsed = std.json.parseFromSlice(KeyfileWire, allocator, keyfile_json, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return KeyfileError.MalformedKeyfile;
    };
    errdefer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.sigil, keyfile_version) or
        !std.mem.eql(u8, parsed.value.kdf, kdf_name))
    {
        return KeyfileError.UnsupportedKeyfileVersion;
    }
    return parsed;
}

/// Decode a printable-binary field into a fixed-size buffer, refusing any
/// length but the expected one. A short field would otherwise leave stack
/// garbage in the tail of the buffer.
fn decodeExact(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    out: []u8,
) (KeyfileError || std.mem.Allocator.Error)!void {
    const decoded = pb.decode(allocator, encoded, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return KeyfileError.MalformedKeyfile;
    };
    defer allocator.free(decoded);
    if (decoded.len != out.len) return KeyfileError.MalformedKeyfile;
    @memcpy(out, decoded);
}

fn deriveKey(
    allocator: std.mem.Allocator,
    out: *[XChaCha20Poly1305.key_length]u8,
    passphrase: []const u8,
    salt: *const [salt_len]u8,
    params: KdfParams,
) (KeyfileError || std.mem.Allocator.Error)!void {
    // Single-threaded on purpose: a key-derivation result that varied with the
    // host's core count would be a keyfile that opens on one machine and not
    // another. `init_single_threaded` needs no allocator and no teardown.
    var threaded: std.Io.Threaded = .init_single_threaded;
    argon2.kdf(
        allocator,
        out,
        passphrase,
        salt,
        .{ .t = params.t, .m = params.m, .p = params.p },
        .argon2id,
        threaded.io(),
    ) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return KeyfileError.BadKdfParams;
    };
}

const aad_prefix = "sigil-" ++ keyfile_version;
const aad_len = aad_prefix.len + 4 + 4 + 4 + salt_len + core.public_key_len;

/// Everything outside the ciphertext that must not be alterable, laid out
/// identically by the writer and the reader. Fixed-width fields, so no
/// delimiter can be smuggled between them.
fn buildAad(
    buf: *[aad_len]u8,
    params: KdfParams,
    salt: *const [salt_len]u8,
    public_key: *const [core.public_key_len]u8,
) []const u8 {
    var w: usize = 0;
    @memcpy(buf[w..][0..aad_prefix.len], aad_prefix);
    w += aad_prefix.len;
    std.mem.writeInt(u32, buf[w..][0..4], params.t, .little);
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], params.m, .little);
    w += 4;
    std.mem.writeInt(u32, buf[w..][0..4], params.p, .little);
    w += 4;
    @memcpy(buf[w..][0..salt_len], salt);
    w += salt_len;
    @memcpy(buf[w..][0..core.public_key_len], public_key);
    w += core.public_key_len;
    return buf[0..w];
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Cheap parameters so the suite stays fast. The production defaults are
/// asserted separately, below, so making tests quick cannot quietly weaken
/// what a real keyfile is protected with.
///
/// `m` deliberately has headroom above argon2's own floor (it rejects
/// `m/8 < p`). At the floor, bumping `p` in the tamper test tripped argon2's
/// parameter validation *before* the AEAD ever ran — which passes for the
/// wrong reason and would have hidden a missing AAD binding.
const cheap: KdfParams = .{ .t = 1, .m = 64, .p = 1 };

const test_salt: [salt_len]u8 = @splat(0x11);
const test_nonce: [nonce_len]u8 = @splat(0x22);
const test_seed: [seed_len]u8 = @splat(0xA5);

/// RFC 8032 section 7.1. Each seed→public-key mapping and each signature below
/// was independently confirmed against Node's crypto before being committed;
/// see the matching note in verify.zig. Do not add an unverified row.
const rfc8032 = [_]struct {
    seed: []const u8,
    public_key: []const u8,
    message: []const u8,
    signature: []const u8,
}{
    .{
        .seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
        .public_key = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        .message = "",
        .signature = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    },
    .{
        .seed = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
        .public_key = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        .message = "72",
        .signature = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    },
    .{
        .seed = "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
        .public_key = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        .message = "af82",
        .signature = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
    },
    .{
        .seed = "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
        .public_key = "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
        .message = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        .signature = "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
    },
};

test "RFC 8032: a seed derives the standard public key" {
    for (rfc8032, 0..) |v, i| {
        var seed: [seed_len]u8 = undefined;
        var want: [core.public_key_len]u8 = undefined;
        _ = try std.fmt.hexToBytes(&seed, v.seed);
        _ = try std.fmt.hexToBytes(&want, v.public_key);

        const kp = try keyPairFromSeed(&seed);
        testing.expectEqualSlices(u8, &want, &kp.public_key) catch |e| {
            std.debug.print("RFC 8032 vector {d}: derived the wrong public key\n", .{i});
            return e;
        };
    }
}

test "RFC 8032: signatures reproduce byte-for-byte" {
    // Ed25519 is deterministic by design: the same key over the same bytes
    // yields the same 64 bytes every time, on every implementation. So this is
    // not "our signer agrees with our verifier" — it is our signer agreeing
    // with the standard, which is a far harder thing to accidentally satisfy.
    for (rfc8032, 0..) |v, i| {
        var seed: [seed_len]u8 = undefined;
        var want: [core.signature_len]u8 = undefined;
        var msg_buf: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(&seed, v.seed);
        _ = try std.fmt.hexToBytes(&want, v.signature);
        const msg = try std.fmt.hexToBytes(msg_buf[0 .. v.message.len / 2], v.message);

        const kp = try keyPairFromSeed(&seed);
        const got = try signPayload(msg, kp);
        testing.expectEqualSlices(u8, &want, &got) catch |e| {
            std.debug.print("RFC 8032 vector {d}: signature does not match the standard\n", .{i});
            return e;
        };
    }
}

test "seal produces an envelope the verifier accepts" {
    const a = testing.allocator;
    const kp = try keyPairFromSeed(&test_seed);
    const payload = "max_major = \"1\"\nproduct = \"mecha-validate\"\n";

    const env = try seal(a, payload, kp);
    defer a.free(env);

    const got = try envelope.verifyEnvelope(a, env, &kp.public_key);
    defer a.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "keyfile round-trips through the right passphrase" {
    const a = testing.allocator;
    const file = try wrapKey(a, &test_seed, "correct horse battery staple", &test_salt, &test_nonce, cheap);
    defer a.free(file);

    const got = try unwrapKey(a, file, "correct horse battery staple");
    try testing.expectEqualSlices(u8, &test_seed, &got);
}

test "the keyfile never contains the seed in the clear" {
    // The entire point of encrypting at rest is that a stray backup is inert.
    // Assert it against the actual bytes rather than trusting that we called
    // the AEAD correctly.
    const a = testing.allocator;
    const file = try wrapKey(a, &test_seed, "hunter2", &test_salt, &test_nonce, cheap);
    defer a.free(file);

    try testing.expect(std.mem.indexOf(u8, file, &test_seed) == null);

    // And the same for a seed with no repeated bytes, so the check cannot pass
    // merely because 0xA5 repeated is unlikely to appear by chance.
    var varied: [seed_len]u8 = undefined;
    for (&varied, 0..) |*b, i| b.* = @intCast(i +% 7);
    const file2 = try wrapKey(a, &varied, "hunter2", &test_salt, &test_nonce, cheap);
    defer a.free(file2);
    try testing.expect(std.mem.indexOf(u8, file2, &varied) == null);
}

test "a wrong passphrase fails authentication rather than yielding a wrong seed" {
    const a = testing.allocator;
    const file = try wrapKey(a, &test_seed, "right", &test_salt, &test_nonce, cheap);
    defer a.free(file);

    try testing.expectError(error.AuthenticationFailed, unwrapKey(a, file, "wrong"));
    try testing.expectError(error.AuthenticationFailed, unwrapKey(a, file, ""));
    try testing.expectError(error.AuthenticationFailed, unwrapKey(a, file, "right "));
}

test "every authenticated keyfile field is bound: tampering with any of them fails" {
    // The KDF parameters, salt and public key sit outside the ciphertext, so
    // they are only safe if they are covered as associated data. Downgrading
    // `t` or `m` to 1 would otherwise make an offline attack on the passphrase
    // dramatically cheaper, and the reader would never notice.
    const a = testing.allocator;
    const file = try wrapKey(a, &test_seed, "pass", &test_salt, &test_nonce, cheap);
    defer a.free(file);

    const tampers = [_]struct { find: []const u8, replace: []const u8, what: []const u8 }{
        .{ .find = "\"t\":1", .replace = "\"t\":9", .what = "time cost" },
        .{ .find = "\"m\":64", .replace = "\"m\":72", .what = "memory cost" },
        .{ .find = "\"p\":1", .replace = "\"p\":2", .what = "parallelism" },
    };

    for (tampers) |t| {
        const at = std.mem.indexOf(u8, file, t.find) orelse {
            std.debug.print("keyfile has no {s} field to tamper with: {s}\n", .{ t.what, file });
            return error.TestUnexpectedResult;
        };
        const bad = try std.mem.concat(a, u8, &.{
            file[0..at], t.replace, file[at + t.find.len ..],
        });
        defer a.free(bad);
        testing.expectError(error.AuthenticationFailed, unwrapKey(a, bad, "pass")) catch |e| {
            std.debug.print("tampering with the {s} was NOT detected\n", .{t.what});
            return e;
        };
    }

    // Same for the byte-valued fields. Flip a bit in the DECODED value and
    // re-encode, rather than editing the encoded text directly: scribbling on
    // the text usually lands mid-glyph and gets caught as invalid UTF-8, which
    // passes the test for the wrong reason and would hide a missing AAD
    // binding. (That path is worth having too — see the test below.)
    const byte_fields = [_][]const u8{
        "\"salt\":\"", "\"nonce\":\"", "\"ciphertext\":\"", "\"public\":\"",
    };
    for (byte_fields) |marker| {
        const bad = try mutateEncodedField(a, file, marker);
        defer a.free(bad);
        testing.expectError(error.AuthenticationFailed, unwrapKey(a, bad, "pass")) catch |e| {
            std.debug.print("tampering with {s} was NOT detected\n", .{marker});
            return e;
        };
    }
}

/// Flip one bit of a printable-binary field's DECODED value and re-encode it,
/// producing a keyfile that is still structurally perfect and still decodes to
/// the right number of bytes — so only the AEAD can catch it.
fn mutateEncodedField(
    allocator: std.mem.Allocator,
    file: []const u8,
    marker: []const u8,
) ![]u8 {
    const start = std.mem.indexOf(u8, file, marker).? + marker.len;
    const end = start + std.mem.indexOfScalar(u8, file[start..], '"').?;

    const decoded = try pb.decode(allocator, file[start..end], .{});
    defer allocator.free(decoded);
    decoded[0] ^= 0x01;

    const re_encoded = try pb.encode(allocator, decoded, .{});
    defer allocator.free(re_encoded);

    return std.mem.concat(allocator, u8, &.{ file[0..start], re_encoded, file[end..] });
}

test "a keyfile corrupted mid-glyph is refused as malformed, not decoded blindly" {
    const a = testing.allocator;
    const file = try wrapKey(a, &test_seed, "pass", &test_salt, &test_nonce, cheap);
    defer a.free(file);

    const at = std.mem.indexOf(u8, file, "\"salt\":\"").? + "\"salt\":\"".len;
    const bad = try a.dupe(u8, file);
    defer a.free(bad);
    bad[at] = if (bad[at] == 'a') 'b' else 'a'; // lands inside a multi-byte glyph

    try testing.expectError(error.MalformedKeyfile, unwrapKey(a, bad, "pass"));
}

test "the public key is readable without the passphrase" {
    // So `sigil pubkey` can print the key to embed in a product without ever
    // asking for, or touching, the secret.
    const a = testing.allocator;
    const kp = try keyPairFromSeed(&test_seed);
    const file = try wrapKey(a, &test_seed, "secret", &test_salt, &test_nonce, cheap);
    defer a.free(file);

    const got = try keyfilePublicKey(a, file);
    try testing.expectEqualSlices(u8, &kp.public_key, &got);
}

test "different salt or nonce yields different ciphertext for the same seed" {
    const a = testing.allocator;
    const other_salt: [salt_len]u8 = @splat(0x33);
    const other_nonce: [nonce_len]u8 = @splat(0x44);

    const base = try wrapKey(a, &test_seed, "p", &test_salt, &test_nonce, cheap);
    defer a.free(base);
    const salted = try wrapKey(a, &test_seed, "p", &other_salt, &test_nonce, cheap);
    defer a.free(salted);
    const nonced = try wrapKey(a, &test_seed, "p", &test_salt, &other_nonce, cheap);
    defer a.free(nonced);

    try testing.expect(!std.mem.eql(u8, base, salted));
    try testing.expect(!std.mem.eql(u8, base, nonced));
}

test "a malformed keyfile is rejected, not misread" {
    const a = testing.allocator;
    const cases = [_][]const u8{
        "",
        "not json",
        "{}",
        "{\"sigil\":\"secret-key-v1\"}",
        // A future format version must not be guessed at.
        "{\"sigil\":\"secret-key-v99\",\"kdf\":\"Argon2id\",\"t\":1,\"m\":8,\"p\":1," ++
            "\"salt\":\"x\",\"nonce\":\"y\",\"ciphertext\":\"z\",\"public\":\"w\"}",
    };
    for (cases) |c| {
        _ = unwrapKey(a, c, "p") catch continue;
        std.debug.print("malformed keyfile was accepted: {s}\n", .{c});
        return error.TestUnexpectedResult;
    }
}

test "the shipped KDF defaults are the strong ones" {
    // Guards against someone lowering the cost to speed up a test run and never
    // putting it back. 64 MiB / t=3 is comfortably above the OWASP floor.
    try testing.expectEqual(@as(u32, 3), default_kdf_params.t);
    try testing.expectEqual(@as(u32, 64 * 1024), default_kdf_params.m);
    try testing.expectEqual(@as(u24, 1), default_kdf_params.p);
}
