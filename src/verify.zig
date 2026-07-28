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

test "RFC 8032 known-answer vectors" {
    // An oracle nobody here wrote. Every other test in this file signs with our
    // own keypair and then checks our own verifier — which proves the two agree
    // but could not catch both of them being wrong the same way (a swapped byte
    // order, a mis-sliced key). These triples come from RFC 8032 section 7.1
    // and pin sigil to the standard rather than to itself.
    //
    // Provenance: each vector below was independently confirmed against Node's
    // crypto.verify, and all but the empty-message case additionally against
    // `openssl pkeyutl -verify` (OpenSSL's pkeyutl cannot process a zero-length
    // message at all — a limitation of that tool, not of the vector). Do not
    // add a vector here that has not been checked the same way.
    const Vector = struct { public_key: []const u8, message: []const u8, sig: []const u8 };
    const vectors = [_]Vector{
        .{
            .public_key = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
            .message = "",
            .sig = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        },
        .{
            .public_key = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
            .message = "72",
            .sig = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
        },
        .{
            .public_key = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
            .message = "af82",
            .sig = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
        },
        .{
            // The SHA-512("abc") test case: a 64-byte message.
            .public_key = "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
            .message = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
            .sig = "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
        },
    };

    for (vectors, 0..) |v, i| {
        var pk: [public_key_len]u8 = undefined;
        var sig: [signature_len]u8 = undefined;
        var msg: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(&pk, v.public_key);
        _ = try std.fmt.hexToBytes(&sig, v.sig);
        const m = try std.fmt.hexToBytes(msg[0 .. v.message.len / 2], v.message);

        verify(m, &sig, &pk) catch |e| {
            std.debug.print("RFC 8032 vector {d} failed to verify: {s}\n", .{ i, @errorName(e) });
            return e;
        };

        // And the same vector must be REJECTED once a single message bit moves,
        // so a verifier that accepted everything could not pass this test.
        if (m.len > 0) {
            var tampered = msg;
            tampered[0] ^= 0x01;
            try std.testing.expectError(
                Error.BadSignature,
                verify(tampered[0..m.len], &sig, &pk),
            );
        }
    }
}
