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
const Edwards25519 = std.crypto.ecc.Edwards25519;

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
///
/// `BadPublicKey` and `BadSignature` are kept strictly apart. Only the second
/// is an accusation against the document; the first says the *key* is wrong,
/// which is a configuration failure and sends the operator somewhere else
/// entirely. Collapsing them is the same defect class as reporting an
/// allocation failure as a forgery.
pub fn verify(
    payload: []const u8,
    sig: *const [signature_len]u8,
    public_key: *const [public_key_len]u8,
) Error!void {
    const pk = Ed25519.PublicKey.fromBytes(public_key.*) catch return Error.BadPublicKey;

    // Low-order keys are screened here rather than left to trip the verifier
    // downstream. Two reasons, and the second is the load-bearing one:
    //
    //  1. Classification. A low-order point has no private counterpart, so no
    //     document under it is a forgery claim worth adjudicating — the key is
    //     broken or substituted. Upstream surfaces this as IdentityElement,
    //     which lands in the same bucket as a genuine forgery unless caught.
    //  2. It pins the property rather than inheriting it. sigil's security
    //     otherwise rests on upstream Zig's cofactored verifier happening to
    //     reject these; if that ever relaxed, a substituted low-order key would
    //     validate *any* signature over *any* message, and nothing here would
    //     have noticed. See the small-order corpus in the tests below.
    //
    // Costs one extra point decode per verify, which is noise next to the
    // scalar multiplications that follow.
    const point = Edwards25519.fromBytes(public_key.*) catch return Error.BadPublicKey;
    point.rejectLowOrder() catch return Error.BadPublicKey;

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

// ── Public-key validation ──────────────────────────────────────────────────

/// The eight points of small order on Edwards25519, in canonical encoding.
///
/// Published constants (they appear verbatim in the libsodium and ed25519-donna
/// test suites), but this file does not take them on faith: the first test
/// below multiplies each by the cofactor and asserts the result is the
/// identity, which is the definition of small order. A typo in this table
/// therefore fails loudly instead of silently shrinking the corpus.
pub const small_order_points = [_][public_key_len]u8{
    hex32("0100000000000000000000000000000000000000000000000000000000000000"), // identity
    hex32("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"), // order 2
    hex32("0000000000000000000000000000000000000000000000000000000000000000"), // order 4
    hex32("0000000000000000000000000000000000000000000000000000000000000080"), // order 4
    hex32("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05"), // order 8
    hex32("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a"), // order 8
    hex32("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85"), // order 8
    hex32("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa"), // order 8
};

fn hex32(comptime s: *const [64:0]u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "the small-order corpus really is small-order" {
    // The independent oracle for the table above. Nothing here trusts the
    // comments; 8P == identity is checked arithmetically for every entry.
    for (small_order_points, 0..) |bytes, i| {
        const p = Edwards25519.fromBytes(bytes) catch |e| {
            std.debug.print("small_order_points[{d}] does not decode: {s}\n", .{ i, @errorName(e) });
            return e;
        };
        p.clearCofactor().rejectIdentity() catch continue; // 8P == identity: correct
        std.debug.print("small_order_points[{d}] is NOT small order\n", .{i});
        return error.TestUnexpectedResult;
    }
}

test "every low-order public key is reported as a key problem, not a forgery" {
    // Classifier over the whole set, not one example. A low-order key cannot
    // have a private counterpart, so a document presented under one is never a
    // forgery claim to adjudicate — it is a broken or substituted key, and
    // saying "NOT AUTHENTIC" about the document sends the operator hunting for
    // the wrong bug. This is the same misclassification as reporting an OOM as
    // a forgery.
    //
    // It also pins a property sigil's whole security rests on but never owned:
    // upstream Zig happens to trip over these keys downstream and return
    // IdentityElement. If a future release made cofactored verification accept
    // them, that is universal forgery — any signature over any message under a
    // substituted key — and without this test the suite would stay green
    // through it.
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const payload = "product=mecha-validate\n";
    const sig = try kp.sign(payload, null);

    for (small_order_points, 0..) |bad_key, i| {
        verify(payload, &sig.toBytes(), &bad_key) catch |e| {
            if (e == Error.BadPublicKey) continue;
            std.debug.print("small_order_points[{d}] gave {s}, want BadPublicKey\n", .{ i, @errorName(e) });
            return error.TestUnexpectedResult;
        };
        std.debug.print("small_order_points[{d}] was ACCEPTED\n", .{i});
        return error.TestUnexpectedResult;
    }
}

test "a low-order key cannot be used to forge a signature over arbitrary bytes" {
    // The attack the check above forecloses: with a small-order A, cofactored
    // verification can be satisfied by R of small order and s = 0, which
    // validates *any* message. Asserted directly so the property is pinned
    // even if the classification above is ever refactored.
    var forged: [signature_len]u8 = @splat(0); // s = 0
    forged[0..32].* = small_order_points[1]; // R = the order-2 point
    for (small_order_points) |bad_key| {
        try std.testing.expectError(
            Error.BadPublicKey,
            verify("a license I did not pay for", &forged, &bad_key),
        );
    }
}

test "non-canonical public key encodings are rejected as key problems" {
    // y >= p is not a point encoding at all. Distinguished from low-order
    // because it fails at a different place and must not be misfiled either.
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed_a);
    const payload = "product=mecha-validate\n";
    const sig = try kp.sign(payload, null);

    const non_canonical = [_][public_key_len]u8{
        hex32("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        hex32("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"), // y == p
        hex32("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"), // y == p+1
    };
    for (non_canonical, 0..) |bad_key, i| {
        verify(payload, &sig.toBytes(), &bad_key) catch |e| {
            if (e == Error.BadPublicKey) continue;
            std.debug.print("non_canonical[{d}] gave {s}, want BadPublicKey\n", .{ i, @errorName(e) });
            return error.TestUnexpectedResult;
        };
        std.debug.print("non_canonical[{d}] was ACCEPTED\n", .{i});
        return error.TestUnexpectedResult;
    }
}

test "specificity: real keys are never mistaken for bad keys" {
    // Without this, "return BadPublicKey always" would pass every test above.
    // Both arms matter: a good key over its own signature must verify, and a
    // good key over someone else's signature must still say BadSignature —
    // the rejection has to keep its own name.
    const seeds = [_][Ed25519.KeyPair.seed_length]u8{
        test_seed_a,
        test_seed_b,
        @splat(0x00),
        @splat(0xFF),
        @splat(0x01),
    };
    const payload = "product=mecha-validate\nmax_major=1\n";
    for (seeds, 0..) |seed, i| {
        const kp = try Ed25519.KeyPair.generateDeterministic(seed);
        const sig = try kp.sign(payload, null);
        verify(payload, &sig.toBytes(), &kp.public_key.toBytes()) catch |e| {
            std.debug.print("seed {d}: honest key rejected with {s}\n", .{ i, @errorName(e) });
            return e;
        };

        const other = try Ed25519.KeyPair.generateDeterministic(seeds[(i + 1) % seeds.len]);
        if (!std.mem.eql(u8, &kp.public_key.toBytes(), &other.public_key.toBytes())) {
            try std.testing.expectError(
                Error.BadSignature,
                verify(payload, &sig.toBytes(), &other.public_key.toBytes()),
            );
        }
    }
}
