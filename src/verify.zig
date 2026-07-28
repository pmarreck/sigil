//! The Ed25519 primitive. Pure, allocation-free, std-only.
//!
//! THE ONE INVARIANT: the signature covers the payload bytes EXACTLY as given.
//! sigil never canonicalizes, re-orders, or re-serializes anything. That is what
//! lets the JSON envelope be reformatted, pretty-printed, or have whitespace
//! inserted without breaking verification — and it is also why sigil needs no
//! collation, no locale, and no JSON canonicalization scheme.
//!
//! This file is the entire dependency budget of a verifying consumer:
//! `std.crypto.sign.Ed25519` and nothing else. Everything an embedder must
//! trust to answer "is this license real?" lives here.

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

// ── Tests ──────────────────────────────────────────────────────────────────
//
// Fixed seeds, never Ed25519.KeyPair.generate(): a test that reaches for the
// system RNG has an invisible input and can fail on one run in a million with
// no way to reproduce it. Deterministic keys make every failure replayable.

pub const test_seed_a: [Ed25519.KeyPair.seed_length]u8 = @splat(0xA5);
pub const test_seed_b: [Ed25519.KeyPair.seed_length]u8 = @splat(0x5A);

test "round trip: a signature over the exact bytes verifies" {
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const payload = "product=mecha-validate\nmax_major=1\n";
    const sig = try kp.sign(payload, null);
    try verify(payload, &sig.toBytes(), &kp.public_key.toBytes());
}

test "one flipped payload byte is rejected" {
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
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
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const honest = "max_major=1\n";
    const greedy = "max_major=9\n";
    const sig = try kp.sign(honest, null);
    try std.testing.expectError(
        Error.BadSignature,
        verify(greedy, &sig.toBytes(), &kp.public_key.toBytes()),
    );
}

test "a signature from a different key is rejected" {
    const mine = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const theirs = try Ed25519.KeyPair.generateDeterministic(test_seed_b);
    const payload = "product=mecha-validate\n";
    const sig = try theirs.sign(payload, null);
    try std.testing.expectError(
        Error.BadSignature,
        verify(payload, &sig.toBytes(), &mine.public_key.toBytes()),
    );
}

test "empty payload is verifiable, not an error" {
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const sig = try kp.sign("", null);
    try verify("", &sig.toBytes(), &kp.public_key.toBytes());
}
