//! The C ABI for signing. **This never ships to a customer.**
//!
//! Compiled into `libsigil_sign.a`, which only the `sigil` CLI links. Mecha
//! Validate and Mecha Rotshield link `libsigil.a` and get none of these
//! symbols, so a shipped product cannot mint a license — the code is not in
//! the binary. `tests/test_no_signing_symbols` holds that to account with `nm`.
//!
//! Note what is deliberately absent: nothing here hands a secret key, or even a
//! seed, back across the boundary. `sigil_seal` takes a keyfile and a
//! passphrase and returns a finished envelope; the seed exists only inside Zig,
//! on a stack buffer that is wiped before return. The CLI never holds key
//! material it could accidentally log, swap out, or write to the wrong file.
//!
//! This file is the adapter layer, so this is where randomness lives. The pure
//! core in sign.zig takes seeds, salts and nonces as parameters and is fully
//! deterministic.

const std = @import("std");
const sign = @import("sign.zig");
const paper = @import("paper.zig");
const core = @import("verify.zig");
const builtin = @import("builtin");

/// See the note in ffi.zig: `testing.allocator` fails on a leak, `c_allocator`
/// cannot see one, so a hardcoded c_allocator made the suite blind to leaks in
/// the FFI.
const alloc = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

pub const SIGIL_OK: c_int = 0;
pub const SIGIL_ERR_NULL_ARGUMENT: c_int = -3;
pub const SIGIL_ERR_BUFFER_TOO_SMALL: c_int = -9;
pub const SIGIL_ERR_OUT_OF_MEMORY: c_int = -10;
// Signing-side codes continue the same numbering from -20 so a code can never
// mean two different things depending on which library returned it.
pub const SIGIL_ERR_MALFORMED_KEYFILE: c_int = -20;
pub const SIGIL_ERR_UNSUPPORTED_KEYFILE: c_int = -21;
pub const SIGIL_ERR_AUTH_FAILED: c_int = -22;
pub const SIGIL_ERR_BAD_KDF_PARAMS: c_int = -23;
pub const SIGIL_ERR_BAD_SEED: c_int = -24;
pub const SIGIL_ERR_EMPTY_PASSPHRASE: c_int = -25;
pub const SIGIL_ERR_NO_ENTROPY: c_int = -26;
pub const SIGIL_ERR_NOT_HOT_BUNDLE: c_int = -27;
pub const SIGIL_ERR_TOO_LARGE_FOR_QR: c_int = -28;

pub const SIGIL_PAPER_KEYFILE: c_int = 0;
pub const SIGIL_PAPER_HOT_BUNDLE: c_int = 1;

/// One artifact to put on a page. Mirrors `sigil_paper_artifact` in the header.
pub const SigilPaperArtifact = extern struct {
    kind: c_int,
    label: ?[*:0]const u8,
    filename: ?[*:0]const u8,
    bytes: ?[*]const u8,
    bytes_len: usize,
    /// 32 bytes, or NULL when unknown.
    pubkey: ?[*]const u8,
};

/// Generate a fresh key and return the passphrase-encrypted keyfile text.
///
/// The seed is drawn from the OS entropy source, used, and wiped; it is never
/// visible to the caller. Losing the keyfile or the passphrase means losing the
/// ability to sign, which is the intended trade.
export fn sigil_keygen(
    passphrase: ?[*]const u8,
    passphrase_len: usize,
    out: ?[*]u8,
    out_cap: usize,
    out_len: ?*usize,
) c_int {
    const pw = passphrase orelse return SIGIL_ERR_NULL_ARGUMENT;
    const n = out_len orelse return SIGIL_ERR_NULL_ARGUMENT;
    if (passphrase_len == 0) return SIGIL_ERR_EMPTY_PASSPHRASE;

    var seed: [sign.seed_len]u8 = undefined;
    var salt: [sign.salt_len]u8 = undefined;
    var nonce: [sign.nonce_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    io.randomSecure(&seed) catch return SIGIL_ERR_NO_ENTROPY;
    io.randomSecure(&salt) catch return SIGIL_ERR_NO_ENTROPY;
    io.randomSecure(&nonce) catch return SIGIL_ERR_NO_ENTROPY;

    const keyfile = sign.wrapKey(
        alloc,
        &seed,
        pw[0..passphrase_len],
        &salt,
        &nonce,
        sign.default_kdf_params,
    ) catch |e| return errorToCode(e);
    defer alloc.free(keyfile);

    return copyOut(keyfile, out, out_cap, n);
}

/// Sign `payload` with the key in `keyfile` and return a finished envelope.
///
/// One call on purpose: unwrapping and signing separately would mean a seed
/// crossing the FFI, and a seed that crosses the FFI is a seed that can end up
/// in a log line or a core dump.
export fn sigil_seal(
    keyfile: ?[*]const u8,
    keyfile_len: usize,
    passphrase: ?[*]const u8,
    passphrase_len: usize,
    payload: ?[*]const u8,
    payload_len: usize,
    out: ?[*]u8,
    out_cap: usize,
    out_len: ?*usize,
) c_int {
    const kf = keyfile orelse return SIGIL_ERR_NULL_ARGUMENT;
    const pw = passphrase orelse return SIGIL_ERR_NULL_ARGUMENT;
    const p = payload orelse return SIGIL_ERR_NULL_ARGUMENT;
    const n = out_len orelse return SIGIL_ERR_NULL_ARGUMENT;

    var keyfile_provider = sign.EncryptedKeyfileProvider.init(
        alloc,
        kf[0..keyfile_len],
        pw[0..passphrase_len],
    ) catch |e| return errorToCode(e);
    defer keyfile_provider.deinit();

    const env = sign.seal(
        alloc,
        p[0..payload_len],
        keyfile_provider.signer(),
    ) catch |e| return errorToCode(e);
    defer alloc.free(env);

    return copyOut(env, out, out_cap, n);
}

/// Derive the public key from a keyfile. Requires the passphrase, because the
/// key is computed from the decrypted seed rather than read from a field.
///
/// It used to take no passphrase and read a stored `public` value. That made
/// the key a developer embeds in a shipped product attacker-controlled: anyone
/// who could write the keyfile chose what `sigil pubkey` printed. The field is
/// gone, so there is nothing left to splice.
export fn sigil_keyfile_public_key(
    keyfile: ?[*]const u8,
    keyfile_len: usize,
    passphrase: ?[*]const u8,
    passphrase_len: usize,
    public_key_out: ?[*]u8,
) c_int {
    const kf = keyfile orelse return SIGIL_ERR_NULL_ARGUMENT;
    const pw = passphrase orelse return SIGIL_ERR_NULL_ARGUMENT;
    const out = public_key_out orelse return SIGIL_ERR_NULL_ARGUMENT;

    const pk = sign.keyfilePublicKey(
        alloc,
        kf[0..keyfile_len],
        pw[0..passphrase_len],
    ) catch |e| return errorToCode(e);
    @memcpy(out[0..pk.len], &pk);
    return SIGIL_OK;
}

/// Generate a fresh key and return BOTH custody artifacts from the one seed:
/// the passphrase-encrypted keyfile and the sealed hot bundle (PKCS#8 for
/// restore-to-online). Made together at generation because that is the only
/// moment the seed exists in the clear; there is deliberately no later export
/// path from a keyfile. Both buffers are sized before either is written, so a
/// too-small buffer leaves nothing half-written.
export fn sigil_keygen_with_recovery(
    passphrase: ?[*]const u8,
    passphrase_len: usize,
    keyfile_out: ?[*]u8,
    keyfile_cap: usize,
    keyfile_len: ?*usize,
    bundle_out: ?[*]u8,
    bundle_cap: usize,
    bundle_len: ?*usize,
) c_int {
    const pw = passphrase orelse return SIGIL_ERR_NULL_ARGUMENT;
    const kn = keyfile_len orelse return SIGIL_ERR_NULL_ARGUMENT;
    const bn = bundle_len orelse return SIGIL_ERR_NULL_ARGUMENT;
    if (passphrase_len == 0) return SIGIL_ERR_EMPTY_PASSPHRASE;

    var seed: [sign.seed_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    var salt: [sign.salt_len]u8 = undefined;
    var nonce: [sign.nonce_len]u8 = undefined;
    var bundle_salt: [sign.salt_len]u8 = undefined;
    var bundle_nonce: [sign.nonce_len]u8 = undefined;

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    io.randomSecure(&seed) catch return SIGIL_ERR_NO_ENTROPY;
    io.randomSecure(&salt) catch return SIGIL_ERR_NO_ENTROPY;
    io.randomSecure(&nonce) catch return SIGIL_ERR_NO_ENTROPY;
    io.randomSecure(&bundle_salt) catch return SIGIL_ERR_NO_ENTROPY;
    io.randomSecure(&bundle_nonce) catch return SIGIL_ERR_NO_ENTROPY;

    const keyfile = sign.wrapKey(
        alloc,
        &seed,
        pw[0..passphrase_len],
        &salt,
        &nonce,
        sign.default_kdf_params,
    ) catch |e| return errorToCode(e);
    defer alloc.free(keyfile);
    const bundle = sign.wrapHotBundle(
        alloc,
        &seed,
        pw[0..passphrase_len],
        &bundle_salt,
        &bundle_nonce,
        sign.default_kdf_params,
    ) catch |e| return errorToCode(e);
    defer alloc.free(bundle);

    kn.* = keyfile.len;
    bn.* = bundle.len;
    if (keyfile.len > keyfile_cap or bundle.len > bundle_cap) return SIGIL_ERR_BUFFER_TOO_SMALL;
    const rc = copyOut(keyfile, keyfile_out, keyfile_cap, kn);
    if (rc != SIGIL_OK) return rc;
    return copyOut(bundle, bundle_out, bundle_cap, bn);
}

/// Open a hot bundle and return its PKCS#8 as PEM text. This is the ONE place
/// a private key crosses this boundary, by design (custody contract v1.2
/// section 2, Peter 2026-09-28): its sole consumer is a pipe into
/// `wrangler secret put`. A keyfile is refused with SIGIL_ERR_NOT_HOT_BUNDLE
/// before any decryption; nothing is written on any failure.
export fn sigil_hot_bundle_open(
    bundle: ?[*]const u8,
    bundle_len: usize,
    passphrase: ?[*]const u8,
    passphrase_len: usize,
    out: ?[*]u8,
    out_cap: usize,
    out_len: ?*usize,
) c_int {
    const b = bundle orelse return SIGIL_ERR_NULL_ARGUMENT;
    const pw = passphrase orelse return SIGIL_ERR_NULL_ARGUMENT;
    const n = out_len orelse return SIGIL_ERR_NULL_ARGUMENT;

    var der = sign.openHotBundle(alloc, b[0..bundle_len], pw[0..passphrase_len]) catch |e| return errorToCode(e);
    defer std.crypto.secureZero(u8, &der);
    const pem = sign.pkcs8ToPem(alloc, &der) catch |e| return errorToCode(e);
    defer {
        std.crypto.secureZero(u8, pem);
        alloc.free(pem);
    }
    return copyOut(pem, out, out_cap, n);
}

/// Render printable cold copies (custody contract v1.3 (c)): one page per
/// artifact, each a QR code plus the same base64 as selectable text plus the
/// identifying text. Sealed bytes only; nothing here decrypts anything.
/// `date` is the caller's YYYY-MM-DD, so the output is reproducible.
export fn sigil_paper_render(
    artifacts: ?[*]const SigilPaperArtifact,
    count: usize,
    date: ?[*:0]const u8,
    out: ?[*]u8,
    out_cap: usize,
    out_len: ?*usize,
) c_int {
    const arts = artifacts orelse return SIGIL_ERR_NULL_ARGUMENT;
    const d = date orelse return SIGIL_ERR_NULL_ARGUMENT;
    const n = out_len orelse return SIGIL_ERR_NULL_ARGUMENT;
    if (count == 0) return SIGIL_ERR_NULL_ARGUMENT;

    const list = alloc.alloc(paper.Artifact, count) catch return SIGIL_ERR_OUT_OF_MEMORY;
    defer alloc.free(list);
    for (arts[0..count], 0..) |a, i| {
        const label = a.label orelse return SIGIL_ERR_NULL_ARGUMENT;
        const filename = a.filename orelse return SIGIL_ERR_NULL_ARGUMENT;
        const bytes = a.bytes orelse return SIGIL_ERR_NULL_ARGUMENT;
        list[i] = .{
            .kind = if (a.kind == SIGIL_PAPER_HOT_BUNDLE) .hot_bundle else .keyfile,
            .label = std.mem.span(label),
            .filename = std.mem.span(filename),
            .bytes = bytes[0..a.bytes_len],
            .pubkey = if (a.pubkey) |pk| pk[0..32].* else null,
        };
    }
    const pdf = paper.render(alloc, list, .{ .date = std.mem.span(d), .sigil_version = core.version }) catch |e| return errorToCode(e);
    defer alloc.free(pdf);
    return copyOut(pdf, out, out_cap, n);
}

/// Human-readable name for a code returned by this library. Never NULL.
export fn sigil_sign_strerror(code: c_int) [*:0]const u8 {
    return switch (code) {
        SIGIL_OK => "ok",
        SIGIL_ERR_NULL_ARGUMENT => "required argument was NULL",
        SIGIL_ERR_BUFFER_TOO_SMALL => "output buffer too small",
        SIGIL_ERR_OUT_OF_MEMORY => "out of memory",
        SIGIL_ERR_MALFORMED_KEYFILE => "keyfile is not a well-formed sigil keyfile",
        SIGIL_ERR_UNSUPPORTED_KEYFILE => "keyfile was written by a newer sigil",
        SIGIL_ERR_AUTH_FAILED => "wrong passphrase, or the keyfile has been altered",
        SIGIL_ERR_BAD_KDF_PARAMS => "keyfile records unusable key-derivation parameters",
        SIGIL_ERR_BAD_SEED => "keyfile does not contain a usable key",
        SIGIL_ERR_EMPTY_PASSPHRASE => "a passphrase is required",
        SIGIL_ERR_NO_ENTROPY => "could not read from the system entropy source",
        SIGIL_ERR_NOT_HOT_BUNDLE => "not a hot bundle (a keyfile cannot be opened into a seed)",
        SIGIL_ERR_TOO_LARGE_FOR_QR => "artifact is too large for a single QR code",
        else => "unknown error",
    };
}

fn copyOut(src: []const u8, out: ?[*]u8, out_cap: usize, out_len: *usize) c_int {
    out_len.* = src.len;
    if (src.len > out_cap) return SIGIL_ERR_BUFFER_TOO_SMALL;
    if (out == null) return SIGIL_ERR_NULL_ARGUMENT;
    if (src.len != 0) @memcpy(out.?[0..src.len], src);
    return SIGIL_OK;
}

/// Single place where Zig errors become C codes, so the two cannot drift.
fn errorToCode(e: anyerror) c_int {
    return switch (e) {
        error.OutOfMemory => SIGIL_ERR_OUT_OF_MEMORY,
        error.MalformedKeyfile => SIGIL_ERR_MALFORMED_KEYFILE,
        error.UnsupportedKeyfileVersion => SIGIL_ERR_UNSUPPORTED_KEYFILE,
        error.AuthenticationFailed => SIGIL_ERR_AUTH_FAILED,
        error.BadKdfParams => SIGIL_ERR_BAD_KDF_PARAMS,
        error.NotAHotBundle => SIGIL_ERR_NOT_HOT_BUNDLE,
        error.DataTooLong => SIGIL_ERR_TOO_LARGE_FOR_QR,
        error.BadSeed, error.BadSecretKey, error.ProviderFailure => SIGIL_ERR_BAD_SEED,
        else => SIGIL_ERR_MALFORMED_KEYFILE,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "FFI: keygen, seal and verify are one working loop" {
    // Keygen uses real entropy, so this test cannot assert an exact key. What
    // it can assert — and what actually matters — is that a key minted by the
    // signing library produces an envelope the SHIPPING verifier accepts.
    var keyfile: [1024]u8 = undefined;
    var keyfile_len: usize = 0;
    try testing.expectEqual(
        SIGIL_OK,
        sigil_keygen("correct horse".ptr, "correct horse".len, &keyfile, keyfile.len, &keyfile_len),
    );

    const payload = "max_major = \"1\"\nproduct = \"mecha-validate\"\n";
    var env: [2048]u8 = undefined;
    var env_len: usize = 0;
    try testing.expectEqual(SIGIL_OK, sigil_seal(
        &keyfile,
        keyfile_len,
        "correct horse".ptr,
        "correct horse".len,
        payload.ptr,
        payload.len,
        &env,
        env.len,
        &env_len,
    ));

    var pk: [32]u8 = undefined;
    try testing.expectEqual(SIGIL_OK, sigil_keyfile_public_key(&keyfile, keyfile_len, "correct horse".ptr, "correct horse".len, &pk));

    const verified = try @import("lib.zig").verifyEnvelope(testing.allocator, env[0..env_len], &pk);
    defer testing.allocator.free(verified);
    try testing.expectEqualStrings(payload, verified);
}

test "FFI: sealing with the wrong passphrase fails and writes nothing" {
    var keyfile: [1024]u8 = undefined;
    var keyfile_len: usize = 0;
    try testing.expectEqual(
        SIGIL_OK,
        sigil_keygen("right".ptr, "right".len, &keyfile, keyfile.len, &keyfile_len),
    );

    var env: [2048]u8 = @splat(0xAA);
    var env_len: usize = 0;
    try testing.expectEqual(SIGIL_ERR_AUTH_FAILED, sigil_seal(
        &keyfile,
        keyfile_len,
        "wrong".ptr,
        "wrong".len,
        "x".ptr,
        1,
        &env,
        env.len,
        &env_len,
    ));
    try testing.expectEqual(@as(u8, 0xAA), env[0]);
}

test "FFI: an empty passphrase is refused at keygen" {
    // Encryption at rest is the whole custody decision; an unencrypted keyfile
    // must not be reachable by passing nothing.
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_EMPTY_PASSPHRASE,
        sigil_keygen("".ptr, 0, &buf, buf.len, &len),
    );
}

test "FFI: NULL arguments are rejected without trapping" {
    var len: usize = 0;
    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_keygen(null, 0, null, 0, &len));
    try testing.expectEqual(
        SIGIL_ERR_NULL_ARGUMENT,
        sigil_seal(null, 0, null, 0, null, 0, null, 0, &len),
    );
    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_keyfile_public_key(null, 0, null, 0, null));
}

test "FFI: a too-small buffer reports the required size instead of overflowing" {
    var keyfile: [1024]u8 = undefined;
    var keyfile_len: usize = 0;
    try testing.expectEqual(
        SIGIL_OK,
        sigil_keygen("pw".ptr, 2, &keyfile, keyfile.len, &keyfile_len),
    );

    var tiny: [4]u8 = @splat(0xAA);
    var needed: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_BUFFER_TOO_SMALL,
        sigil_keygen("pw".ptr, 2, &tiny, tiny.len, &needed),
    );
    try testing.expect(needed > tiny.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xAA, 0xAA, 0xAA }, &tiny);
}

test "FFI: every code has its own message" {
    const codes = [_]c_int{
        SIGIL_OK,                    SIGIL_ERR_NULL_ARGUMENT,
        SIGIL_ERR_BUFFER_TOO_SMALL,  SIGIL_ERR_OUT_OF_MEMORY,
        SIGIL_ERR_MALFORMED_KEYFILE, SIGIL_ERR_UNSUPPORTED_KEYFILE,
        SIGIL_ERR_AUTH_FAILED,       SIGIL_ERR_BAD_KDF_PARAMS,
        SIGIL_ERR_BAD_SEED,          SIGIL_ERR_EMPTY_PASSPHRASE,
        SIGIL_ERR_NO_ENTROPY,        SIGIL_ERR_NOT_HOT_BUNDLE,
        SIGIL_ERR_TOO_LARGE_FOR_QR,
    };
    for (codes, 0..) |a_code, i| {
        const a_msg = std.mem.span(sigil_sign_strerror(a_code));
        try testing.expect(!std.mem.eql(u8, a_msg, "unknown error"));
        for (codes[i + 1 ..]) |b_code| {
            try testing.expect(!std.mem.eql(u8, a_msg, std.mem.span(sigil_sign_strerror(b_code))));
        }
    }
}

test "keygen draws fresh randomness every time" {
    // Two keygens with the same passphrase must not produce the same keyfile.
    // If the entropy call ever silently degrades to a constant, every customer
    // gets the same signing key — the failure that ends the business.
    var a_buf: [1024]u8 = undefined;
    var b_buf: [1024]u8 = undefined;
    var a_len: usize = 0;
    var b_len: usize = 0;
    try testing.expectEqual(SIGIL_OK, sigil_keygen("same".ptr, 4, &a_buf, a_buf.len, &a_len));
    try testing.expectEqual(SIGIL_OK, sigil_keygen("same".ptr, 4, &b_buf, b_buf.len, &b_len));
    try testing.expect(!std.mem.eql(u8, a_buf[0..a_len], b_buf[0..b_len]));

    var a_pk: [32]u8 = undefined;
    var b_pk: [32]u8 = undefined;
    try testing.expectEqual(SIGIL_OK, sigil_keyfile_public_key(&a_buf, a_len, "same".ptr, 4, &a_pk));
    try testing.expectEqual(SIGIL_OK, sigil_keyfile_public_key(&b_buf, b_len, "same".ptr, 4, &b_pk));
    try testing.expect(!std.mem.eql(u8, &a_pk, &b_pk));
}

test "FFI: keygen with recovery yields a bundle whose PKCS#8 names the keyfile's public key" {
    var keyfile: [1024]u8 = undefined;
    var keyfile_len: usize = 0;
    var bundle: [1024]u8 = undefined;
    var bundle_len: usize = 0;
    try testing.expectEqual(SIGIL_OK, sigil_keygen_with_recovery(
        "pw".ptr,
        2,
        &keyfile,
        keyfile.len,
        &keyfile_len,
        &bundle,
        bundle.len,
        &bundle_len,
    ));
    try testing.expect(!std.mem.eql(u8, keyfile[0..keyfile_len], bundle[0..bundle_len]));

    var pem: [512]u8 = undefined;
    var pem_len: usize = 0;
    try testing.expectEqual(SIGIL_OK, sigil_hot_bundle_open(&bundle, bundle_len, "pw".ptr, 2, &pem, pem.len, &pem_len));

    // Independent path to the public key: decode the PEM with std's base64,
    // take the RFC 8410 seed, derive with std's Ed25519. No sign.zig helper.
    const head = "-----BEGIN PRIVATE KEY-----\n";
    const tail = "\n-----END PRIVATE KEY-----\n";
    const text = pem[0..pem_len];
    try testing.expect(std.mem.startsWith(u8, text, head));
    try testing.expect(std.mem.endsWith(u8, text, tail));
    var der: [48]u8 = undefined;
    try std.base64.standard.Decoder.decode(&der, text[head.len .. text.len - tail.len]);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(der[16..48].*);

    var pk: [32]u8 = undefined;
    try testing.expectEqual(SIGIL_OK, sigil_keyfile_public_key(&keyfile, keyfile_len, "pw".ptr, 2, &pk));
    try testing.expectEqualSlices(u8, &pk, &kp.public_key.toBytes());
}

test "FFI: a keyfile is not a hot bundle and opening it writes nothing" {
    var keyfile: [1024]u8 = undefined;
    var keyfile_len: usize = 0;
    try testing.expectEqual(SIGIL_OK, sigil_keygen("pw".ptr, 2, &keyfile, keyfile.len, &keyfile_len));

    var pem: [512]u8 = @splat(0xAA);
    var pem_len: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_NOT_HOT_BUNDLE,
        sigil_hot_bundle_open(&keyfile, keyfile_len, "pw".ptr, 2, &pem, pem.len, &pem_len),
    );
    try testing.expectEqual(@as(u8, 0xAA), pem[0]);
}

test "FFI: hot bundle open refuses the wrong passphrase, NULLs and a small buffer" {
    var keyfile: [1024]u8 = undefined;
    var keyfile_len: usize = 0;
    var bundle: [1024]u8 = undefined;
    var bundle_len: usize = 0;
    try testing.expectEqual(SIGIL_OK, sigil_keygen_with_recovery(
        "pw".ptr,
        2,
        &keyfile,
        keyfile.len,
        &keyfile_len,
        &bundle,
        bundle.len,
        &bundle_len,
    ));

    var pem: [512]u8 = @splat(0xAA);
    var pem_len: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_AUTH_FAILED,
        sigil_hot_bundle_open(&bundle, bundle_len, "no".ptr, 2, &pem, pem.len, &pem_len),
    );
    try testing.expectEqual(@as(u8, 0xAA), pem[0]);

    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_hot_bundle_open(null, 0, null, 0, null, 0, &pem_len));
    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_keygen_with_recovery(null, 0, null, 0, null, null, 0, null));

    var tiny: [4]u8 = @splat(0xAA);
    var needed: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_BUFFER_TOO_SMALL,
        sigil_hot_bundle_open(&bundle, bundle_len, "pw".ptr, 2, &tiny, tiny.len, &needed),
    );
    try testing.expect(needed > tiny.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xAA, 0xAA, 0xAA }, &tiny);
}

test "FFI: paper renders a PDF for a keyfile artifact" {
    const bytes = "{\"sigil\":\"secret-key-v1\"}\n";
    const pk = [_]u8{0x42} ** 32;
    const arts = [_]SigilPaperArtifact{.{
        .kind = SIGIL_PAPER_KEYFILE,
        .label = "Mecha Validate beta-license (TEST)",
        .filename = "validate_beta.key",
        .bytes = bytes.ptr,
        .bytes_len = bytes.len,
        .pubkey = &pk,
    }};
    var out: [262144]u8 = undefined;
    var out_len: usize = 0;
    try testing.expectEqual(SIGIL_OK, sigil_paper_render(&arts, arts.len, "2026-09-28", &out, out.len, &out_len));
    try testing.expect(std.mem.startsWith(u8, out[0..out_len], "%PDF-1.4"));
    try testing.expect(std.mem.indexOf(u8, out[0..out_len], "validate_beta.key") != null);
    try testing.expect(std.mem.indexOf(u8, out[0..out_len], "sigil 0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, out[0..out_len], "42" ** 32) != null);
}

test "FFI: paper refuses NULLs, an empty set and a small buffer without writing" {
    var out_len: usize = 0;
    var tiny: [4]u8 = @splat(0xAA);
    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_paper_render(null, 1, "2026-09-28", &tiny, tiny.len, &out_len));
    const bytes = "x";
    const arts = [_]SigilPaperArtifact{.{ .kind = SIGIL_PAPER_HOT_BUNDLE, .label = "l", .filename = "f", .bytes = bytes.ptr, .bytes_len = 1, .pubkey = null }};
    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_paper_render(&arts, 0, "2026-09-28", &tiny, tiny.len, &out_len));
    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_paper_render(&arts, 1, null, &tiny, tiny.len, &out_len));
    try testing.expectEqual(SIGIL_ERR_BUFFER_TOO_SMALL, sigil_paper_render(&arts, 1, "2026-09-28", &tiny, tiny.len, &out_len));
    try testing.expect(out_len > tiny.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xAA, 0xAA, 0xAA }, &tiny);
    // Too much for any QR code is its own answer, not a malformed keyfile.
    const huge = "y" ** 3000;
    const big = [_]SigilPaperArtifact{.{ .kind = SIGIL_PAPER_KEYFILE, .label = "l", .filename = "f", .bytes = huge.ptr, .bytes_len = huge.len, .pubkey = null }};
    var out: [262144]u8 = undefined;
    try testing.expectEqual(SIGIL_ERR_TOO_LARGE_FOR_QR, sigil_paper_render(&big, 1, "2026-09-28", &out, out.len, &out_len));
}
