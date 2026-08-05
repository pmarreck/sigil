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
        SIGIL_ERR_NO_ENTROPY,
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
