//! The C ABI — the real public API.
//!
//! Mecha Validate and Mecha Rotshield consume sigil through this boundary, and
//! the C CLI in `cli/` dogfoods the very same surface (it is written in C
//! precisely so that it *cannot* `@import` the Zig core and quietly bypass it).
//!
//! Every `export fn sigil_*` lives here and nowhere else, so the importable
//! `sigil` Zig module emits no C symbols and cannot collide at link time.
//!
//! Functions here never trap: an FFI boundary that panics takes the host
//! application down, so every failure is a negative return code.

const std = @import("std");
const sigil = @import("lib.zig");

pub const SIGIL_OK: c_int = 0;
pub const SIGIL_ERR_BAD_SIGNATURE: c_int = -1;
pub const SIGIL_ERR_BAD_PUBLIC_KEY: c_int = -2;
pub const SIGIL_ERR_NULL_ARGUMENT: c_int = -3;
pub const SIGIL_ERR_MALFORMED_JSON: c_int = -4;
pub const SIGIL_ERR_MISSING_FIELD: c_int = -5;
pub const SIGIL_ERR_UNSUPPORTED_SIGTYPE: c_int = -6;
pub const SIGIL_ERR_MALFORMED_ENCODING: c_int = -7;
pub const SIGIL_ERR_BAD_SIGNATURE_LENGTH: c_int = -8;
pub const SIGIL_ERR_BUFFER_TOO_SMALL: c_int = -9;
pub const SIGIL_ERR_OUT_OF_MEMORY: c_int = -10;

/// Verify a detached Ed25519 signature over `payload_len` bytes of `payload`.
/// Returns SIGIL_OK (0) on success, negative on failure. Never traps.
export fn sigil_verify(
    payload: ?[*]const u8,
    payload_len: usize,
    sig: ?[*]const u8,
    public_key: ?[*]const u8,
) c_int {
    const p = payload orelse return SIGIL_ERR_NULL_ARGUMENT;
    const s = sig orelse return SIGIL_ERR_NULL_ARGUMENT;
    const k = public_key orelse return SIGIL_ERR_NULL_ARGUMENT;

    // A zero-length payload is legal to verify; only NULL is an argument error.
    sigil.verify(
        p[0..payload_len],
        s[0..sigil.signature_len],
        k[0..sigil.public_key_len],
    ) catch |e| return errorToCode(e);
    return SIGIL_OK;
}

/// Verify a JSON envelope and copy the AUTHENTICATED payload into `payload_out`.
///
/// There is no way to get payload bytes out of this function without them
/// having verified, which is how "verify before parsing" is enforced against
/// callers who never read the docs.
///
/// On SIGIL_OK, `*payload_len_out` is the payload length. On
/// SIGIL_ERR_BUFFER_TOO_SMALL it is the capacity required. printable-binary
/// only ever expands, so a buffer of `envelope_len` bytes always suffices and
/// a caller may skip the two-pass dance entirely.
export fn sigil_verify_envelope(
    envelope: ?[*]const u8,
    envelope_len: usize,
    public_key: ?[*]const u8,
    payload_out: ?[*]u8,
    payload_out_cap: usize,
    payload_len_out: ?*usize,
) c_int {
    const e = envelope orelse return SIGIL_ERR_NULL_ARGUMENT;
    const k = public_key orelse return SIGIL_ERR_NULL_ARGUMENT;
    const out_len = payload_len_out orelse return SIGIL_ERR_NULL_ARGUMENT;
    if (payload_out == null and payload_out_cap != 0) return SIGIL_ERR_NULL_ARGUMENT;

    const payload = sigil.verifyEnvelope(
        std.heap.c_allocator,
        e[0..envelope_len],
        k[0..sigil.public_key_len],
    ) catch |err| return errorToCode(err);
    defer std.heap.c_allocator.free(payload);

    out_len.* = payload.len;
    if (payload.len > payload_out_cap) return SIGIL_ERR_BUFFER_TOO_SMALL;
    if (payload.len != 0) @memcpy(payload_out.?[0..payload.len], payload);
    return SIGIL_OK;
}

export fn sigil_version() [*:0]const u8 {
    return "0.1.0";
}

export fn sigil_signature_len() usize {
    return sigil.signature_len;
}

export fn sigil_public_key_len() usize {
    return sigil.public_key_len;
}

/// Human-readable name for a code returned by this API. Never NULL, so a caller
/// can splice it into an error message without a null check.
export fn sigil_strerror(code: c_int) [*:0]const u8 {
    return switch (code) {
        SIGIL_OK => "ok",
        SIGIL_ERR_BAD_SIGNATURE => "signature does not verify under this public key",
        SIGIL_ERR_BAD_PUBLIC_KEY => "not a valid Ed25519 public key",
        SIGIL_ERR_NULL_ARGUMENT => "required argument was NULL",
        SIGIL_ERR_MALFORMED_JSON => "envelope is not a well-formed JSON object",
        SIGIL_ERR_MISSING_FIELD => "envelope is missing data, sigtype or sig",
        SIGIL_ERR_UNSUPPORTED_SIGTYPE => "sigtype is not \"Ed25519\"",
        SIGIL_ERR_MALFORMED_ENCODING => "printable-binary value could not be decoded",
        SIGIL_ERR_BAD_SIGNATURE_LENGTH => "decoded signature was not 64 bytes",
        SIGIL_ERR_BUFFER_TOO_SMALL => "output buffer too small for the payload",
        SIGIL_ERR_OUT_OF_MEMORY => "out of memory",
        else => "unknown error",
    };
}

/// Single place where Zig errors become C codes, so the two never drift apart.
fn errorToCode(e: anyerror) c_int {
    return switch (e) {
        error.BadSignature, error.MalformedSignature => SIGIL_ERR_BAD_SIGNATURE,
        error.BadPublicKey => SIGIL_ERR_BAD_PUBLIC_KEY,
        error.MalformedJson => SIGIL_ERR_MALFORMED_JSON,
        error.MissingField => SIGIL_ERR_MISSING_FIELD,
        error.UnsupportedSigType => SIGIL_ERR_UNSUPPORTED_SIGTYPE,
        error.MalformedEncoding => SIGIL_ERR_MALFORMED_ENCODING,
        error.BadSignatureLength => SIGIL_ERR_BAD_SIGNATURE_LENGTH,
        error.OutOfMemory => SIGIL_ERR_OUT_OF_MEMORY,
        else => SIGIL_ERR_MALFORMED_JSON,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;
const test_seed_a: [Ed25519.KeyPair.seed_length]u8 = @splat(0xA5);

test "FFI: NULL arguments are rejected without trapping" {
    try testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_verify(null, 0, null, null));

    var len: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_NULL_ARGUMENT,
        sigil_verify_envelope(null, 0, null, null, 0, &len),
    );
}

test "FFI: reports the same result as the Zig API" {
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const payload = "product=mecha-rotshield\n";
    const sig = try kp.sign(payload, null);
    const sig_bytes = sig.toBytes();
    const pk_bytes = kp.public_key.toBytes();

    try testing.expectEqual(
        SIGIL_OK,
        sigil_verify(payload.ptr, payload.len, &sig_bytes, &pk_bytes),
    );

    var bad = sig_bytes;
    bad[0] ^= 0xff;
    try testing.expectEqual(
        SIGIL_ERR_BAD_SIGNATURE,
        sigil_verify(payload.ptr, payload.len, &bad, &pk_bytes),
    );
}

test "FFI: advertised lengths match the constants consumers will allocate" {
    try testing.expectEqual(@as(usize, 64), sigil_signature_len());
    try testing.expectEqual(@as(usize, 32), sigil_public_key_len());
}

test "FFI: envelope verification returns the authenticated payload" {
    const a = testing.allocator;
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const pk = kp.public_key.toBytes();
    const payload = "product = \"mecha-validate\"\nmax_major = \"1\"\n";

    const sig = try kp.sign(payload, null);
    const env = try sigil.writeEnvelope(a, payload, &sig.toBytes());
    defer a.free(env);

    var buf: [512]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(
        SIGIL_OK,
        sigil_verify_envelope(env.ptr, env.len, &pk, &buf, buf.len, &len),
    );
    try testing.expectEqualStrings(payload, buf[0..len]);
}

test "FFI: a too-small buffer reports the required size instead of overflowing" {
    const a = testing.allocator;
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const pk = kp.public_key.toBytes();
    const payload = "v = \"1\"\nproduct = \"mecha-validate\"\n";

    const sig = try kp.sign(payload, null);
    const env = try sigil.writeEnvelope(a, payload, &sig.toBytes());
    defer a.free(env);

    var tiny: [4]u8 = @splat(0xAA);
    var len: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_BUFFER_TOO_SMALL,
        sigil_verify_envelope(env.ptr, env.len, &pk, &tiny, tiny.len, &len),
    );
    try testing.expectEqual(payload.len, len);
    // Nothing was written past the caller's capacity — the buffer is untouched.
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xAA, 0xAA, 0xAA }, &tiny);
}

test "FFI: a bad envelope yields a specific code, and every code has a message" {
    const pk: [32]u8 = @splat(0);
    const env = "{\"data\":\"x\",\"sigtype\":\"none\",\"sig\":\"y\"}";
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(
        SIGIL_ERR_UNSUPPORTED_SIGTYPE,
        sigil_verify_envelope(env.ptr, env.len, &pk, &buf, buf.len, &len),
    );

    // Every code this API can return must have its own message; a caller that
    // prints sigil_strerror() should never show the same text for two causes.
    const codes = [_]c_int{
        SIGIL_OK,                        SIGIL_ERR_BAD_SIGNATURE,
        SIGIL_ERR_BAD_PUBLIC_KEY,        SIGIL_ERR_NULL_ARGUMENT,
        SIGIL_ERR_MALFORMED_JSON,        SIGIL_ERR_MISSING_FIELD,
        SIGIL_ERR_UNSUPPORTED_SIGTYPE,   SIGIL_ERR_MALFORMED_ENCODING,
        SIGIL_ERR_BAD_SIGNATURE_LENGTH,  SIGIL_ERR_BUFFER_TOO_SMALL,
        SIGIL_ERR_OUT_OF_MEMORY,
    };
    for (codes, 0..) |a_code, i| {
        const a_msg = std.mem.span(sigil_strerror(a_code));
        try testing.expect(a_msg.len > 0);
        try testing.expect(!std.mem.eql(u8, a_msg, "unknown error"));
        for (codes[i + 1 ..]) |b_code| {
            try testing.expect(!std.mem.eql(u8, a_msg, std.mem.span(sigil_strerror(b_code))));
        }
    }
}
