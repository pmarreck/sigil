//! sigil — verify Ed25519-signed documents whose payload stays human-scannable.
//!
//! THE ONE INVARIANT: the signature covers the payload bytes EXACTLY as given.
//! sigil never canonicalizes, re-orders, or re-serializes anything. That is what
//! lets the JSON envelope be reformatted, pretty-printed, or have whitespace
//! inserted without breaking verification — and it is also why sigil needs no
//! collation, no locale, and no JSON canonicalization scheme.
//!
//! Envelope (transport only, never signed):
//!   {"data":"<printable-binary of payload>","sigtype":"Ed25519",
//!    "sig":"<printable-binary of raw signature>"}
//!
//! Verify order matters: decode → VERIFY → only then parse the payload. Never
//! interpret bytes you have not authenticated.
//!
//! This module is pure: no I/O, no allocation beyond caller-provided buffers.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const public_key_len = Ed25519.PublicKey.encoded_length;
pub const signature_len = Ed25519.Signature.encoded_length;

pub const Error = error{
    /// Signature did not verify against this public key over these bytes.
    BadSignature,
    /// The public key was not a valid Ed25519 point.
    BadPublicKey,
    /// The signature blob was structurally invalid.
    MalformedSignature,
};

/// Verify `sig` over `payload` under `public_key`.
///
/// `payload` is the decoded document bytes — NOT the JSON envelope, and NOT the
/// printable-binary text. Callers decode first, then pass the exact bytes here.
///
/// Constant-time in the underlying primitive; returns an error rather than a
/// bool so a caller cannot accidentally ignore the result the way `if (!ok)`
/// invites.
pub fn verify(
    payload: []const u8,
    sig: *const [signature_len]u8,
    public_key: *const [public_key_len]u8,
) Error!void {
    const pk = Ed25519.PublicKey.fromBytes(public_key.*) catch return Error.BadPublicKey;
    const signature = Ed25519.Signature.fromBytes(sig.*);
    signature.verify(payload, pk) catch return Error.BadSignature;
}

// ── C FFI ────────────────────────────────────────────────────────────────────
// The FFI is the real public API: Mecha Validate (Rust/GPUI + Swift + Win32) and
// Mecha Rotshield both consume it. The C CLI in cli/ dogfoods this same surface.

pub const SIGIL_OK: c_int = 0;
pub const SIGIL_ERR_BAD_SIGNATURE: c_int = -1;
pub const SIGIL_ERR_BAD_PUBLIC_KEY: c_int = -2;
pub const SIGIL_ERR_NULL_ARGUMENT: c_int = -3;

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
    verify(p[0..payload_len], s[0..signature_len], k[0..public_key_len]) catch |e| return switch (e) {
        Error.BadSignature, Error.MalformedSignature => SIGIL_ERR_BAD_SIGNATURE,
        Error.BadPublicKey => SIGIL_ERR_BAD_PUBLIC_KEY,
    };
    return SIGIL_OK;
}

export fn sigil_version() [*:0]const u8 {
    return "0.1.0";
}

export fn sigil_signature_len() usize {
    return signature_len;
}

export fn sigil_public_key_len() usize {
    return public_key_len;
}

// ── Tests ──────────────────────────────────────────────────────────────────
//
// Fixed seeds, never Ed25519.KeyPair.generate(): a test that reaches for the
// system RNG has an invisible input and can fail on one run in a million with
// no way to reproduce it. Deterministic keys make every failure replayable.

const seed_a: [Ed25519.KeyPair.seed_length]u8 = @splat(0xA5);
const seed_b: [Ed25519.KeyPair.seed_length]u8 = @splat(0x5A);

test "round trip: a signature over the exact bytes verifies" {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed_a);
    const payload = "product=mecha-validate\nmax_major=1\n";
    const sig = try kp.sign(payload, null);
    try verify(payload, &sig.toBytes(), &kp.public_key.toBytes());
}

test "one flipped payload byte is rejected" {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed_a);
    const payload = "product=mecha-validate\nmax_major=1\n";
    const sig = try kp.sign(payload, null);

    var tampered = payload.*;
    tampered[9] ^= 0x01; // 'm' of "mecha" → one bit
    try std.testing.expectError(
        Error.BadSignature,
        verify(&tampered, &sig.toBytes(), &kp.public_key.toBytes()),
    );
}

test "the max_major upgrade rule cannot be edited without detection" {
    // The commercial rule (same major = free upgrade, major bump = paid) lives
    // in the payload, so this is the attack that matters: bump the number.
    const kp = try Ed25519.KeyPair.generateDeterministic(seed_a);
    const honest = "max_major=1\n";
    const greedy = "max_major=9\n";
    const sig = try kp.sign(honest, null);
    try std.testing.expectError(
        Error.BadSignature,
        verify(greedy, &sig.toBytes(), &kp.public_key.toBytes()),
    );
}

test "a signature from a different key is rejected" {
    const mine = try Ed25519.KeyPair.generateDeterministic(seed_a);
    const theirs = try Ed25519.KeyPair.generateDeterministic(seed_b);
    const payload = "product=mecha-validate\n";
    const sig = try theirs.sign(payload, null);
    try std.testing.expectError(
        Error.BadSignature,
        verify(payload, &sig.toBytes(), &mine.public_key.toBytes()),
    );
}

test "empty payload is verifiable, not an error" {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed_a);
    const sig = try kp.sign("", null);
    try verify("", &sig.toBytes(), &kp.public_key.toBytes());
}

test "FFI: NULL arguments are rejected without trapping" {
    try std.testing.expectEqual(SIGIL_ERR_NULL_ARGUMENT, sigil_verify(null, 0, null, null));
}

test "FFI: reports the same result as the Zig API" {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed_a);
    const payload = "product=mecha-rotshield\n";
    const sig = try kp.sign(payload, null);
    const sig_bytes = sig.toBytes();
    const pk_bytes = kp.public_key.toBytes();

    try std.testing.expectEqual(
        SIGIL_OK,
        sigil_verify(payload.ptr, payload.len, &sig_bytes, &pk_bytes),
    );

    var bad = sig_bytes;
    bad[0] ^= 0xff;
    try std.testing.expectEqual(
        SIGIL_ERR_BAD_SIGNATURE,
        sigil_verify(payload.ptr, payload.len, &bad, &pk_bytes),
    );
}

test "FFI: advertised lengths match the constants consumers will allocate" {
    try std.testing.expectEqual(@as(usize, 64), sigil_signature_len());
    try std.testing.expectEqual(@as(usize, 32), sigil_public_key_len());
}
