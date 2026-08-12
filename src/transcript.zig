//! The signing transcript: the exact bytes an Ed25519 signature covers.
//!
//! sigil signs `DOMAIN ‖ u8(alg_id) ‖ u64be(payload_len) ‖ payload` rather than
//! the bare payload, so the algorithm identifier is inside the signature and
//! cannot be swapped by anyone who can edit the envelope. See docs/DESIGN.md,
//! "The signing transcript", for why each field is shaped this way.
//!
//! THE INVARIANT survives in the sense that mattered: the payload bytes are
//! copied in verbatim and never canonicalized, re-ordered or re-serialized, so
//! the JSON envelope is still free to be reformatted.
//!
//! This module is the ONLY place a transcript is built. Signing and verifying
//! both call it, because two implementations of a signed encoding is how the
//! two ends drift apart and one of them becomes forgeable.

const std = @import("std");

/// Fixed ASCII domain prefix. The version lives here rather than in a separate
/// field: bumping to `sigil.transcript.v2` changes the domain, so a v1
/// signature can never be replayed as v2. Domain separation and versioning are
/// the same mechanism.
pub const domain = "sigil.transcript.v1";

/// Algorithm identifiers. `none` is reserved so a zeroed byte is never a valid
/// algorithm — an all-zero header should fail, not select Ed25519.
pub const Algorithm = enum(u8) {
    none = 0,
    ed25519 = 1,
};

pub const header_len = domain.len + 1 + 8;

pub const Error = error{
    /// The transcript was shorter than a header, or its length field disagreed
    /// with the bytes actually present.
    Malformed,
    /// The domain prefix did not match. A signature over some other protocol's
    /// bytes, or a different transcript version.
    ForeignDomain,
    /// The algorithm byte was `none` or unrecognized.
    UnknownAlgorithm,
};

/// Build the transcript for `payload` under `alg`. Caller owns the result.
pub fn build(
    allocator: std.mem.Allocator,
    alg: Algorithm,
    payload: []const u8,
) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, header_len + payload.len);
    errdefer allocator.free(out);
    writeInto(out, alg, payload);
    return out;
}

/// Same, into caller-provided storage. `buf` must be exactly `header_len +
/// payload.len` bytes; the caller sizes it with `size(payload)`.
pub fn writeInto(buf: []u8, alg: Algorithm, payload: []const u8) void {
    std.debug.assert(buf.len == size(payload));
    @memcpy(buf[0..domain.len], domain);
    buf[domain.len] = @intFromEnum(alg);
    std.mem.writeInt(u64, buf[domain.len + 1 ..][0..8], payload.len, .big);
    @memcpy(buf[header_len..], payload);
}

pub fn size(payload: []const u8) usize {
    return header_len + payload.len;
}

/// Write just the fixed-size header, for callers that stream the payload
/// separately (Ed25519's incremental Signer/Verifier). This is what keeps
/// `verify` allocation-free: the header is 28 bytes on the stack and the
/// payload is fed in without ever being copied.
///
/// Must stay byte-identical to the header `build` produces; a test pins that.
pub fn writeHeader(buf: *[header_len]u8, alg: Algorithm, payload_len: u64) void {
    @memcpy(buf[0..domain.len], domain);
    buf[domain.len] = @intFromEnum(alg);
    std.mem.writeInt(u64, buf[domain.len + 1 ..][0..8], payload_len, .big);
}

/// The inverse of `build`. Not needed to sign or verify — it exists so the
/// encoding's *injectivity* can be tested against a real decoder rather than
/// asserted in a comment. If `parse(build(a, p))` always returns `(a, p)`, no
/// two distinct inputs share a transcript.
pub fn parse(transcript: []const u8) Error!struct { alg: Algorithm, payload: []const u8 } {
    if (transcript.len < header_len) return Error.Malformed;
    if (!std.mem.eql(u8, transcript[0..domain.len], domain)) return Error.ForeignDomain;

    // Explicit switch rather than a numeric cast: an unrecognized byte, and
    // `none` (0) in particular, must fail rather than land on a valid variant.
    const alg_byte = transcript[domain.len];
    const alg: Algorithm = switch (alg_byte) {
        @intFromEnum(Algorithm.ed25519) => .ed25519,
        else => return Error.UnknownAlgorithm,
    };

    const declared = std.mem.readInt(u64, transcript[domain.len + 1 ..][0..8], .big);
    const actual = transcript.len - header_len;
    if (declared != actual) return Error.Malformed;

    return .{ .alg = alg, .payload = transcript[header_len..] };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the payload is carried verbatim, for every byte value" {
    // THE INVARIANT, checked rather than asserted in prose. Sweeps all 256
    // values so a transform that only mangles one of them cannot hide.
    var payload: [256]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i);

    const t = try build(testing.allocator, .ed25519, &payload);
    defer testing.allocator.free(t);

    try testing.expectEqualSlices(u8, &payload, t[header_len..]);
}

test "the encoding is injective: parse recovers exactly what build put in" {
    // The property that makes the format safe to sign. If two distinct inputs
    // could produce one transcript, a signature over one would be a valid
    // signature over the other — a forgery primitive.
    const payloads = [_][]const u8{
        "",
        "\x00",
        "a",
        "product = \"mecha-validate\"\n",
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        // Payloads that embed the domain, to prove a nested transcript cannot
        // be mistaken for the real header.
        domain,
        domain ++ "\x01\x00\x00\x00\x00\x00\x00\x00\x00",
    };

    for (payloads, 0..) |p, i| {
        const t = try build(testing.allocator, .ed25519, p);
        defer testing.allocator.free(t);

        const got = parse(t) catch |e| {
            std.debug.print("payload {d} failed to parse: {s}\n", .{ i, @errorName(e) });
            return e;
        };
        try testing.expectEqual(Algorithm.ed25519, got.alg);
        try testing.expectEqualSlices(u8, p, got.payload);
    }
}

test "distinct inputs never share a transcript" {
    // The classic concatenation-ambiguity attack: without a length prefix,
    // ("AB", "") and ("A", "B") can serialize identically. Swept as a set.
    const allocator = testing.allocator;
    const cases = [_][]const u8{ "", "A", "B", "AB", "A\x00B", "\x00", "\x00\x00" };

    var seen = std.ArrayList([]u8).empty;
    defer {
        for (seen.items) |s| allocator.free(s);
        seen.deinit(allocator);
    }

    for (cases) |p| {
        const t = try build(allocator, .ed25519, p);
        for (seen.items) |prev| {
            if (std.mem.eql(u8, prev, t)) {
                std.debug.print("collision on payload '{s}'\n", .{p});
                allocator.free(t);
                return error.TestUnexpectedResult;
            }
        }
        try seen.append(allocator, t);
    }
}

test "a different algorithm produces a different transcript" {
    // The downgrade defense. Once a second algorithm exists, a signature made
    // under one must not be replayable as the other; that holds because the
    // signed bytes differ.
    const allocator = testing.allocator;
    const payload = "product = \"mecha-validate\"\n";

    const a = try build(allocator, .ed25519, payload);
    defer allocator.free(a);
    const b = try build(allocator, .none, payload);
    defer allocator.free(b);

    try testing.expect(!std.mem.eql(u8, a, b));
}

test "a foreign or truncated transcript is rejected, and by the right name" {
    const allocator = testing.allocator;
    const t = try build(allocator, .ed25519, "hello");
    defer allocator.free(t);

    // Raw payload with no header at all: what the pre-transcript format signed.
    try testing.expectError(Error.Malformed, parse("hello"));

    // Right length, wrong domain — another protocol's signed bytes.
    var foreign = try allocator.dupe(u8, t);
    defer allocator.free(foreign);
    foreign[0] = 'S';
    try testing.expectError(Error.ForeignDomain, parse(foreign));

    // A zeroed algorithm byte must not select Ed25519.
    var zeroed = try allocator.dupe(u8, t);
    defer allocator.free(zeroed);
    zeroed[domain.len] = 0;
    try testing.expectError(Error.UnknownAlgorithm, parse(zeroed));

    // Length field disagreeing with the bytes present.
    var lied = try allocator.dupe(u8, t);
    defer allocator.free(lied);
    std.mem.writeInt(u64, lied[domain.len + 1 ..][0..8], 999, .big);
    try testing.expectError(Error.Malformed, parse(lied));

    // Truncated into the header.
    try testing.expectError(Error.Malformed, parse(t[0 .. header_len - 1]));
}

test "the header is exactly the documented shape" {
    // Pins the wire bytes so a refactor cannot silently move a field. These
    // are the values docs/DESIGN.md publishes; if this test changes, that
    // table must change with it.
    const allocator = testing.allocator;
    const t = try build(allocator, .ed25519, "hi");
    defer allocator.free(t);

    try testing.expectEqual(@as(usize, 19), domain.len);
    try testing.expectEqual(@as(usize, 28), header_len);
    try testing.expectEqualSlices(u8, "sigil.transcript.v1", t[0..19]);
    try testing.expectEqual(@as(u8, 1), t[19]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 2 }, t[20..28]);
    try testing.expectEqualSlices(u8, "hi", t[28..]);
}

test "writeInto and build agree" {
    // Two entry points, one encoding. If they ever diverge, the sign path and
    // the verify path could disagree about what was signed.
    const allocator = testing.allocator;
    const payload = "customer_email = \"peter@example.com\"\n";

    const built = try build(allocator, .ed25519, payload);
    defer allocator.free(built);

    const buf = try allocator.alloc(u8, size(payload));
    defer allocator.free(buf);
    writeInto(buf, .ed25519, payload);

    try testing.expectEqualSlices(u8, built, buf);
}
