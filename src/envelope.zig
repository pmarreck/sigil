//! The JSON envelope — transport only, NEVER signed.
//!
//!   {"data":"<printable-binary of payload>","sigtype":"Ed25519",
//!    "sig":"<printable-binary of the raw 64-byte signature>"}
//!
//! The signature covers the DECODED `data` bytes, never the JSON. That is the
//! whole trick: the envelope may be reformatted, re-ordered, pretty-printed or
//! have whitespace inserted and verification still holds, so sigil needs no
//! canonicalization scheme (cf. RFC 8785) and no collation.
//!
//! Order matters: decode → VERIFY → only then parse the payload. This module
//! enforces that with types rather than documentation: there is no exported way
//! to obtain payload bytes that have not been authenticated.

const std = @import("std");
const pb = @import("printable_binary");
const core = @import("verify.zig");

pub const public_key_len = core.public_key_len;
pub const signature_len = core.signature_len;

/// The only signature algorithm sigil speaks.
///
/// Note carefully what this field is and is not. It is NOT authenticated — an
/// attacker may rewrite it freely, because the envelope is transport. It is a
/// usability check that turns "BadSignature" into a message that says what
/// actually went wrong. The real authority over the algorithm is the caller's
/// public key, which the caller chose. If a second algorithm is ever added it
/// must be pinned by the verifier's own configuration, NEVER selected from this
/// field, or the envelope becomes a downgrade oracle.
pub const sigtype = "Ed25519";

pub const EnvelopeError = error{
    /// Not well-formed JSON, or not a JSON object, or a duplicated key.
    MalformedJson,
    /// One of `data`, `sigtype`, `sig` was absent.
    MissingField,
    /// `sigtype` was present but is not "Ed25519".
    UnsupportedSigType,
    /// A printable-binary value could not be decoded.
    MalformedEncoding,
    /// The decoded signature was not exactly `signature_len` bytes.
    BadSignatureLength,
};

pub const VerifyEnvelopeError = EnvelopeError || core.Error || std.mem.Allocator.Error;

/// The wire shape. Unknown fields are tolerated (docs/DESIGN.md anticipates a
/// `datatype` label), but duplicated fields are not: two parsers disagreeing
/// about which value is real is the classic parser-differential attack, and a
/// verifier has no business having an opinion about which one wins.
const Wire = struct {
    data: []const u8,
    sigtype: []const u8,
    sig: []const u8,
};

/// ASCII bytes a valid envelope can legitimately contain: printable-binary's
/// ASCII subset, plus the five JSON structure characters this format uses.
///
/// The two sets are DISJOINT — printable-binary emits no `"`, `:`, `,`, `{` or
/// `}` — which is the same property that lets `write` splice values in with no
/// escaping pass. Everything else below 0x80 is transport noise by
/// construction: line folds, `>` reply prefixes, stray tabs, terminal wrapping.
///
/// Kept honest by "MFIC: the ASCII allowlist matches what the codec actually
/// emits", which sweeps all 256 byte values. A remapped glyph upstream fails
/// the build rather than silently making valid envelopes unverifiable.
const allowed_ascii =
    ".0123456789@ABCDEFGHIJKLMNOPQRSTUVWXYZ^_abcdefghijklmnopqrstuvwxyz" ++
    "{}\":,";

const ascii_keep: [128]bool = blk: {
    var t = [_]bool{false} ** 128;
    for (allowed_ascii) |c| t[c] = true;
    break :blk t;
};

/// Strip transport noise so an envelope survives email, terminals and
/// copy-paste. O(n), single pass, no allocation beyond the output.
///
/// Safe to be this aggressive because of an ordering property, not a guess:
/// normalization runs BEFORE verification and the signature covers the DECODED
/// payload bytes. If this ever removes something meaningful, the decoded bytes
/// stop matching what was signed and verification FAILS. A bug here can only
/// cause a false rejection, never a false acceptance — availability risk, not
/// authenticity risk. That asymmetry is what licenses the whole approach.
///
/// Bytes >= 0x80 are always kept: they are parts of multi-byte alphabet glyphs,
/// and a fold landing mid-glyph must reassemble cleanly once the fold is gone.
fn normalize(allocator: std.mem.Allocator, envelope_json: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, envelope_json.len);
    errdefer allocator.free(out);
    var n: usize = 0;
    for (envelope_json) |c| {
        if (c >= 0x80 or ascii_keep[c]) {
            out[n] = c;
            n += 1;
        }
    }
    return allocator.realloc(out, n);
}

/// Parse the normalized envelope. Deliberately NOT `std.json`.
///
/// Two reasons, one of them a shipping defect: `std.json`'s number path pulls
/// in 128-bit soft-float symbols (`roundq`, `__divtf3`, …) that no valid
/// envelope can ever reach, and those unresolved symbols made `libsigil.a`
/// unlinkable by a customer's stock `cc`. This format has three string fields
/// and no numbers, so the dependency bought nothing and cost the link.
///
/// Normalization has already removed every byte outside `allowed_ascii`, so a
/// `"` here unambiguously ends a string: printable-binary emits neither `"` nor
/// `\`, and any literal backslash was stripped as noise. That means NO escape
/// handling — which also means an envelope written by some other tool using
/// `\uXXXX` escapes will no longer verify. That is a deliberate narrowing: it
/// removes a class of distinct-but-equivalent encodings, and sigil never emits
/// escapes itself.
fn parseEnvelope(s: []const u8) EnvelopeError!Wire {
    var i: usize = 0;
    if (i == s.len or s[i] != '{') return EnvelopeError.MalformedJson;
    i += 1;

    var data: ?[]const u8 = null;
    var st: ?[]const u8 = null;
    var sg: ?[]const u8 = null;

    if (i < s.len and s[i] == '}') {
        i += 1;
    } else while (true) {
        const key = try scanString(s, &i);
        if (i == s.len or s[i] != ':') return EnvelopeError.MalformedJson;
        i += 1;
        const val = try scanString(s, &i);

        // Duplicates are an error, not last-wins: two `data` fields is a
        // crafted envelope, and silently preferring one is how a reader and a
        // verifier end up disagreeing about what was signed.
        if (std.mem.eql(u8, key, "data")) {
            if (data != null) return EnvelopeError.MalformedJson;
            data = val;
        } else if (std.mem.eql(u8, key, "sigtype")) {
            if (st != null) return EnvelopeError.MalformedJson;
            st = val;
        } else if (std.mem.eql(u8, key, "sig")) {
            if (sg != null) return EnvelopeError.MalformedJson;
            sg = val;
        }
        // Unknown fields are ignored, so the format can gain fields later
        // without old verifiers rejecting new licenses.

        if (i == s.len) return EnvelopeError.MalformedJson;
        if (s[i] == ',') {
            i += 1;
            continue;
        }
        if (s[i] == '}') {
            i += 1;
            break;
        }
        return EnvelopeError.MalformedJson;
    }

    if (i != s.len) return EnvelopeError.MalformedJson; // trailing junk

    return .{
        .data = data orelse return EnvelopeError.MissingField,
        .sigtype = st orelse return EnvelopeError.MissingField,
        .sig = sg orelse return EnvelopeError.MissingField,
    };
}

/// Read one `"…"` token, advancing `i` past the closing quote. Returns a slice
/// INTO the normalized buffer, which the caller must keep alive.
fn scanString(s: []const u8, i: *usize) EnvelopeError![]const u8 {
    if (i.* == s.len or s[i.*] != '"') return EnvelopeError.MalformedJson;
    i.* += 1;
    const start = i.*;
    while (i.* < s.len and s[i.*] != '"') i.* += 1;
    if (i.* == s.len) return EnvelopeError.MalformedJson; // unterminated
    const out = s[start..i.*];
    i.* += 1;
    return out;
}

/// Verify an envelope and return its AUTHENTICATED payload bytes.
///
/// Caller owns the returned slice. There is deliberately no sibling function
/// that extracts the payload without checking the signature: "verify before
/// parsing" is enforced by this signature rather than by a comment someone will
/// skip, so a caller physically cannot interpret unauthenticated bytes.
pub fn verifyEnvelope(
    allocator: std.mem.Allocator,
    envelope_json: []const u8,
    public_key: *const [public_key_len]u8,
) VerifyEnvelopeError![]u8 {
    // Strip transport noise first. This cannot weaken the check: the signature
    // is verified over the decoded payload further down, so anything this
    // removes wrongly shows up as a failed verification, never a false pass.
    const clean = try normalize(allocator, envelope_json);
    defer allocator.free(clean);

    // `std.json` validated UTF-8 as a side effect; a hand-rolled parser must do
    // it deliberately. Without this a truncated multi-byte glyph decodes to
    // something plausible and fails as BadSignature — telling a customer their
    // license is FORGED when it was merely mangled in transit. Structural
    // damage and tampering must stay distinguishable.
    if (!std.unicode.utf8ValidateSlice(clean)) return EnvelopeError.MalformedJson;

    // `wire` holds slices into `clean`, which outlives it via the defer above.
    const wire = try parseEnvelope(clean);

    if (!std.mem.eql(u8, wire.sigtype, sigtype)) return EnvelopeError.UnsupportedSigType;

    const payload = try decodeField(allocator, wire.data);
    errdefer allocator.free(payload);

    const sig = try decodeField(allocator, wire.sig);
    defer allocator.free(sig);
    if (sig.len != signature_len) return EnvelopeError.BadSignatureLength;

    // The moment of truth, over the decoded bytes and nothing else.
    try core.verify(payload, sig[0..signature_len], public_key);
    return payload;
}

/// Serialize an already-signed payload into the envelope.
///
/// Holds no key material and cannot sign; it only packages. Caller owns the
/// returned slice.
///
/// The two encoded values are spliced into the JSON with no escaping pass.
/// That is sound because printable-binary never emits `"`, `\` or a control
/// character — see the all-256-byte sweep in the tests below, which is what
/// keeps this honest if an upstream glyph is ever remapped.
pub const WriteError = std.mem.Allocator.Error || error{
    /// The payload is large enough that its encoded size does not fit in a
    /// usize. Not reachable for a license; reachable for arbitrary documents.
    Overflow,
};

pub fn write(
    allocator: std.mem.Allocator,
    payload: []const u8,
    sig: *const [signature_len]u8,
) WriteError![]u8 {
    const data_enc = try pb.encode(allocator, payload, .{});
    defer allocator.free(data_enc);
    const sig_enc = try pb.encode(allocator, sig, .{});
    defer allocator.free(sig_enc);

    return std.fmt.allocPrint(
        allocator,
        "{{\"data\":\"{s}\",\"sigtype\":\"" ++ sigtype ++ "\",\"sig\":\"{s}\"}}",
        .{ data_enc, sig_enc },
    );
}

// ── Public key files ────────────────────────────────────────────────────────

/// Leading token of a public-key file. Its job is to make a mis-passed file
/// (an envelope, a keyfile, a screenshot of one) fail loudly and immediately
/// rather than turn into 32 bytes of nonsense and a confusing BadSignature.
pub const pubkey_prefix = "sigil-pubkey-v1 ";

/// Render a public key as a one-line file body. Same printable-binary
/// representation the keyfile and the envelope use, so there is exactly one
/// way a key ever appears as text.
pub fn publicKeyToText(
    allocator: std.mem.Allocator,
    public_key: *const [public_key_len]u8,
) WriteError![]u8 {
    const encoded = try pb.encode(allocator, public_key, .{});
    defer allocator.free(encoded);
    return std.mem.concat(allocator, u8, &.{ pubkey_prefix, encoded, "\n" });
}

/// Parse a public-key file body. Tolerates surrounding whitespace and a missing
/// prefix (so a bare encoded key still works), but refuses anything that does
/// not decode to exactly `public_key_len` bytes.
pub fn publicKeyFromText(
    allocator: std.mem.Allocator,
    text: []const u8,
) (EnvelopeError || std.mem.Allocator.Error)![public_key_len]u8 {
    var body = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, body, std.mem.trim(u8, pubkey_prefix, " "))) {
        body = std.mem.trim(u8, body[std.mem.trim(u8, pubkey_prefix, " ").len..], " \t\r\n");
    }
    if (body.len == 0) return EnvelopeError.MalformedEncoding;

    const decoded = try decodeField(allocator, body);
    defer allocator.free(decoded);
    if (decoded.len != public_key_len) return EnvelopeError.MalformedEncoding;

    var out: [public_key_len]u8 = undefined;
    @memcpy(&out, decoded);
    return out;
}

/// printable-binary decode that keeps allocation failure distinguishable from
/// malformed input — collapsing them would report a transient OOM as a forged
/// license, which is exactly the wrong thing to tell a paying customer.
///
/// The alphabet is checked BEFORE decoding, because the decoder is total over
/// valid UTF-8: an unmapped glyph becomes *some* byte rather than an error, so
/// a file mangled in transit came back as "signature does not verify" and
/// `MalformedEncoding` was unreachable for `data` and `sig`. Structural damage
/// and tampering are different accusations and must not share an exit code.
///
/// `pb.validate` is the codec's own oracle rather than a copy of the alphabet
/// kept here, so a remapped glyph upstream cannot leave the two disagreeing.
/// Whitespace flags are 0: `normalize` has already stripped every byte outside
/// the envelope's ASCII allowlist, which contains no whitespace.
///
/// This can only ever reject more, never accept more, so it preserves the
/// module's central asymmetry — a bug here costs availability, not
/// authenticity.
fn decodeField(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) (EnvelopeError || std.mem.Allocator.Error)![]u8 {
    if (pb.validate(encoded, 0).is_valid == 0) return EnvelopeError.MalformedEncoding;
    return pb.decode(allocator, encoded, .{}) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return EnvelopeError.MalformedEncoding;
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const Ed25519 = std.crypto.sign.Ed25519;
const testing = std.testing;

fn testKey(seed: [Ed25519.KeyPair.seed_length]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed);
}

/// Sign and package `payload` in one step, for tests only.
fn sealForTest(allocator: std.mem.Allocator, kp: Ed25519.KeyPair, payload: []const u8) ![]u8 {
    const sig = try kp.sign(payload, null);
    return write(allocator, payload, &sig.toBytes());
}

test "round trip: an envelope we wrote verifies and yields the exact payload" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const payload = "email = \"peter@example.com\"\nmax_major = \"1\"\nproduct = \"mecha-validate\"\n";

    const env = try sealForTest(a, kp, payload);
    defer a.free(env);

    const got = try verifyEnvelope(a, env, &kp.public_key.toBytes());
    defer a.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "THE INVARIANT: reformatting the envelope does not break verification" {
    // This is the entire reason the signature covers the decoded payload rather
    // than the JSON. Whitespace, indentation, key order and trailing newlines
    // are all transport-layer noise; none of them are signed.
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const payload = "v = \"1\"\n";

    const compact = try sealForTest(a, kp, payload);
    defer a.free(compact);

    // Pull the two encoded values back out so we can re-emit them differently.
    const parsed = try std.json.parseFromSlice(
        struct { data: []const u8, sigtype: []const u8, sig: []const u8 },
        a,
        compact,
        .{},
    );
    defer parsed.deinit();

    const d = parsed.value.data;
    const t = parsed.value.sigtype;
    const s = parsed.value.sig;

    const reformattings = [_][]const []const u8{
        // pretty-printed, keys re-ordered, trailing newline
        &.{ "{\n  \"sig\": \"", s, "\",\n  \"sigtype\": \"", t, "\",\n  \"data\": \"", d, "\"\n}\n" },
        // spaces everywhere
        &.{ "{ \"data\" : \"", d, "\" , \"sigtype\" : \"", t, "\" , \"sig\" : \"", s, "\" }" },
        // tabs and CRLF, as a Windows editor would leave it
        &.{ "{\r\n\t\"data\":\"", d, "\",\r\n\t\"sigtype\":\"", t, "\",\r\n\t\"sig\":\"", s, "\"\r\n}\r\n" },
    };

    for (reformattings) |parts| {
        const env = try std.mem.concat(a, u8, parts);
        defer a.free(env);
        const got = try verifyEnvelope(a, env, &kp.public_key.toBytes());
        defer a.free(got);
        try testing.expectEqualStrings(payload, got);
    }
}

test "an unknown extra field is ignored, not fatal" {
    // docs/DESIGN.md anticipates a `datatype` label (toml / json / octet-stream)
    // that the consuming application reads. Adding it must not break verifiers
    // built before it existed.
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const payload = "product = \"mecha-rotshield\"\n";

    const compact = try sealForTest(a, kp, payload);
    defer a.free(compact);

    const with_extra = try std.mem.concat(a, u8, &.{
        compact[0 .. compact.len - 1], ",\"datatype\":\"toml\"}",
    });
    defer a.free(with_extra);

    const got = try verifyEnvelope(a, with_extra, &kp.public_key.toBytes());
    defer a.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "editing max_major inside the envelope is rejected" {
    // The commercially relevant forgery: the free-minor/paid-major rule lives in
    // the payload, so bumping that number IS the attack. Re-encoding the edited
    // payload produces a well-formed envelope with a stale signature.
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const honest = "max_major = \"1\"\n";
    const greedy = "max_major = \"9\"\n";

    const sig = try kp.sign(honest, null);
    const forged = try write(a, greedy, &sig.toBytes());
    defer a.free(forged);

    try testing.expectError(
        error.BadSignature,
        verifyEnvelope(a, forged, &kp.public_key.toBytes()),
    );
}

test "a signature from the wrong key is rejected" {
    const a = testing.allocator;
    const mine = try testKey(core.test_seed_a);
    const theirs = try testKey(core.test_seed_b);

    const env = try sealForTest(a, theirs, "v = \"1\"\n");
    defer a.free(env);

    try testing.expectError(
        error.BadSignature,
        verifyEnvelope(a, env, &mine.public_key.toBytes()),
    );
}

test "tampering with the encoded data string is rejected" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);

    const env = try sealForTest(a, kp, "aaaaaaaa");
    defer a.free(env);

    const tampered = try a.dupe(u8, env);
    defer a.free(tampered);
    // The payload is all ASCII 'a', which printable-binary passes through
    // literally, so this edits exactly one signed byte. Index past the marker
    // rather than searching for 'a' — the key name "data" contains one too.
    const marker = "\"data\":\"";
    const at = std.mem.indexOf(u8, tampered, marker).? + marker.len;
    tampered[at] = 'b';

    try testing.expectError(
        error.BadSignature,
        verifyEnvelope(a, tampered, &kp.public_key.toBytes()),
    );
}

test "a signature of the wrong length is rejected as a length error, not a crash" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);

    // A well-formed envelope carrying a perfectly valid encoding of 63 bytes.
    // Ed25519 signatures are 64; the size check must catch this before anything
    // tries to reinterpret the slice as a fixed-size array.
    const short: [signature_len - 1]u8 = @splat(0x11);
    const short_enc = try pb.encode(a, &short, .{});
    defer a.free(short_enc);
    const data_enc = try pb.encode(a, "v = \"1\"\n", .{});
    defer a.free(data_enc);

    const env = try std.mem.concat(a, u8, &.{
        "{\"data\":\"", data_enc, "\",\"sigtype\":\"", sigtype, "\",\"sig\":\"", short_enc, "\"}",
    });
    defer a.free(env);

    try testing.expectError(
        error.BadSignatureLength,
        verifyEnvelope(a, env, &kp.public_key.toBytes()),
    );
}

test "truncating a multi-byte glyph is caught as malformed JSON, not decoded blindly" {
    // printable-binary encodes most bytes as multi-byte UTF-8. Lopping a byte
    // off the end leaves an incomplete sequence, and a JSON string containing
    // invalid UTF-8 must be refused outright rather than decoded to something
    // plausible — no interpreting bytes we have not authenticated.
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);

    const env = try sealForTest(a, kp, "v = \"1\"\n");
    defer a.free(env);

    const close = std.mem.lastIndexOfScalar(u8, env, '"').?;
    const truncated = try std.mem.concat(a, u8, &.{ env[0 .. close - 1], env[close..] });
    defer a.free(truncated);

    try testing.expectError(
        error.MalformedJson,
        verifyEnvelope(a, truncated, &kp.public_key.toBytes()),
    );
}

test "structurally invalid envelopes are rejected with distinguishable errors" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const pk = kp.public_key.toBytes();

    const cases = [_]struct { env: []const u8, want: anyerror }{
        .{ .env = "", .want = error.MalformedJson },
        .{ .env = "not json at all", .want = error.MalformedJson },
        .{ .env = "[1,2,3]", .want = error.MalformedJson },
        .{ .env = "{\"data\":\"x\",\"sigtype\":\"Ed25519\"}", .want = error.MissingField },
        .{ .env = "{\"sigtype\":\"Ed25519\",\"sig\":\"x\"}", .want = error.MissingField },
        .{ .env = "{\"data\":\"x\",\"sig\":\"y\"}", .want = error.MissingField },
        // A downgrade attempt must not be silently accepted.
        .{ .env = "{\"data\":\"x\",\"sigtype\":\"none\",\"sig\":\"y\"}", .want = error.UnsupportedSigType },
        .{ .env = "{\"data\":\"x\",\"sigtype\":\"ed25519\",\"sig\":\"y\"}", .want = error.UnsupportedSigType },
        // Duplicate keys are the classic parser-differential attack: two readers
        // disagree about which value is real. Refuse to have an opinion.
        .{
            .env = "{\"data\":\"x\",\"data\":\"y\",\"sigtype\":\"Ed25519\",\"sig\":\"z\"}",
            .want = error.MalformedJson,
        },
    };

    for (cases) |c| {
        testing.expectError(c.want, verifyEnvelope(a, c.env, &pk)) catch |e| {
            std.debug.print("case {s}\n", .{c.env});
            return e;
        };
    }
}

test "payload bytes survive verbatim: all 256 byte values" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);

    var payload: [256]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i);

    const env = try sealForTest(a, kp, &payload);
    defer a.free(env);

    const got = try verifyEnvelope(a, env, &kp.public_key.toBytes());
    defer a.free(got);
    try testing.expectEqualSlices(u8, &payload, got);
}

test "a payload that is itself JSON round-trips without escaping trouble" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const payload = "{\"nested\":\"json\",\"path\":\"C:\\\\Users\\\\peter\"}";

    const env = try sealForTest(a, kp, payload);
    defer a.free(env);

    const got = try verifyEnvelope(a, env, &kp.public_key.toBytes());
    defer a.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "an empty payload round-trips" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);

    const env = try sealForTest(a, kp, "");
    defer a.free(env);

    const got = try verifyEnvelope(a, env, &kp.public_key.toBytes());
    defer a.free(got);
    try testing.expectEqualStrings("", got);
}

test "a public key round-trips through its text form" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const pk = kp.public_key.toBytes();

    const text = try publicKeyToText(a, &pk);
    defer a.free(text);
    try testing.expect(std.mem.startsWith(u8, text, pubkey_prefix));
    try testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);

    try testing.expectEqualSlices(u8, &pk, &(try publicKeyFromText(a, text)));
}

test "public key text parsing tolerates formatting but not the wrong thing" {
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const pk = kp.public_key.toBytes();

    const text = try publicKeyToText(a, &pk);
    defer a.free(text);
    const bare = std.mem.trim(u8, text[pubkey_prefix.len..], " \t\r\n");

    // Formatting noise a human or an editor might introduce.
    const tolerated = [_][]const u8{
        text,
        std.mem.trim(u8, text, "\n"),
        bare,
    };
    for (tolerated) |t| {
        const padded = try std.mem.concat(a, u8, &.{ "  \t", t, "\r\n\n" });
        defer a.free(padded);
        try testing.expectEqualSlices(u8, &pk, &(try publicKeyFromText(a, padded)));
    }

    // Anything that is not a 32-byte key must be refused, not truncated or
    // padded into one. Passing the wrong file is the realistic mistake here.
    const sig = try kp.sign("x", null);
    const env = try write(a, "x", &sig.toBytes());
    defer a.free(env);

    const rejected = [_][]const u8{ "", "   \n", "sigil-pubkey-v1 ", bare[0..8], env };
    for (rejected) |r| {
        _ = publicKeyFromText(a, r) catch continue;
        std.debug.print("publicKeyFromText accepted something that is not a key: {s}\n", .{r});
        return error.TestUnexpectedResult;
    }
}

test "MFIC: printable-binary output needs no JSON escaping, swept over every byte" {
    // `write` embeds the encoded strings into JSON with no escaping pass. That
    // is only sound because printable-binary never emits '"', '\' or a control
    // character. Assert it as a classifier over the WHOLE input alphabet rather
    // than on a hand-picked example, because a single remapped glyph upstream
    // would silently start producing invalid — or injectable — JSON.
    //
    // The sweep is complete by construction: multi-byte encodings can only
    // contain UTF-8 lead (>= 0xC2) and continuation (0x80..0xBF) bytes, neither
    // of which can be 0x22, 0x5C or < 0x20. So only single-byte pass-throughs
    // can offend, and all 256 of those appear below.
    const a = testing.allocator;

    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);

    const encoded = try pb.encode(a, &all, .{});
    defer a.free(encoded);

    for (encoded) |c| {
        if (c == '"' or c == '\\' or c < 0x20 or c == 0x7F) {
            std.debug.print("printable-binary emitted JSON-hostile byte 0x{X:0>2}\n", .{c});
            return error.TestUnexpectedResult;
        }
    }
}

// ── Transport mangling (feature: survive email, terminals, copy-paste) ──────

/// Simulate a lossy text transport: hard-wrap every `width` bytes the way a mail
/// client folds a long line, and prefix each resulting line the way a reply
/// quotes it. Deliberately wraps on BYTE boundaries, so it will happily split a
/// multi-byte glyph — that is the hostile case, not an accident.
fn mangleForTest(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    quote: []const u8,
) ![]u8 {
    const lines = (text.len + width - 1) / width;
    var out = try allocator.alloc(u8, text.len + lines * (quote.len + 1));
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const end = @min(i + width, text.len);
        @memcpy(out[n..][0..quote.len], quote);
        n += quote.len;
        @memcpy(out[n..][0 .. end - i], text[i..end]);
        n += end - i;
        out[n] = '\n';
        n += 1;
        i = end;
    }
    return allocator.realloc(out, n);
}

test "an envelope hard-wrapped in transit still verifies" {
    // Mail clients fold long lines. The fold lands inside the quoted values and
    // even mid-glyph, because printable-binary emits multi-byte UTF-8.
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const payload = "email = \"peter@marreck.com\"\nmax_major = \"1\"\n";

    const env = try sealForTest(a, kp, payload);
    defer a.free(env);

    const wrapped = try mangleForTest(a, env, 40, "");
    defer a.free(wrapped);

    const got = try verifyEnvelope(a, wrapped, &kp.public_key.toBytes());
    defer a.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "an envelope carrying email quote prefixes still verifies" {
    // A reply quotes every line with "> ". `>` is NOT in the printable-binary
    // alphabet (0x3E encodes to U+02C3), so a literal one is provably transport
    // noise rather than data.
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const payload = "product = \"mecha-rotshield\"\n";

    const env = try sealForTest(a, kp, payload);
    defer a.free(env);

    const quoted = try mangleForTest(a, env, 50, "> ");
    defer a.free(quoted);

    const got = try verifyEnvelope(a, quoted, &kp.public_key.toBytes());
    defer a.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "MFIC: normalization cannot rescue a tampered payload" {
    // The property that licenses aggressive stripping: normalization runs
    // BEFORE verification and the signature covers the DECODED bytes, so a
    // normalization bug can only cause a false rejection, never a false accept.
    // Mangling a forged envelope must still be a forgery.
    const a = testing.allocator;
    const kp = try testKey(core.test_seed_a);
    const payload = "max_major = \"1\"\n";

    const env = try sealForTest(a, kp, payload);
    defer a.free(env);

    // Flip a byte inside the encoded data value. `1` -> `9` is the commercial
    // attack: the free-minor/paid-major rule lives in that number.
    const forged = try a.dupe(u8, env);
    defer a.free(forged);
    const one = std.mem.indexOfScalar(u8, forged, '1') orelse return error.TestUnexpectedResult;
    forged[one] = '9';

    const mangled = try mangleForTest(a, forged, 30, "> ");
    defer a.free(mangled);

    try testing.expectError(
        core.Error.BadSignature,
        verifyEnvelope(a, mangled, &kp.public_key.toBytes()),
    );
}

test "MFIC: the ASCII allowlist matches what the codec actually emits" {
    // The normalizer keeps ASCII bytes on an allowlist and strips the rest.
    // That constant must never drift from the codec. Sweep all 256 byte values
    // and assert every ASCII byte printable-binary can emit is on the list —
    // so a remapped glyph upstream fails the build instead of silently making
    // valid envelopes unverifiable.
    const a = testing.allocator;
    var all: [256]u8 = undefined;
    for (&all, 0..) |*c, i| c.* = @intCast(i);

    const enc = try pb.encode(a, &all, .{});
    defer a.free(enc);

    for (enc) |c| {
        if (c >= 0x80) continue; // part of a multi-byte glyph; always preserved
        if (std.mem.indexOfScalar(u8, allowed_ascii, c) == null) {
            std.debug.print(
                "codec emits ASCII 0x{X:0>2} ('{c}') which the normalizer would STRIP\n",
                .{ c, c },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "a glyph outside the alphabet is corruption, not a forgery" {
    // Classifier over a set of characters that are valid UTF-8 but carry no
    // printable-binary meaning. The decoder is total over valid UTF-8 — it
    // turns an unmapped glyph into *some* byte rather than refusing — so
    // without an explicit alphabet check every one of these came back as
    // "signature does not verify", i.e. sigil telling a paying customer their
    // license is FORGED when the file was merely mangled. `MalformedEncoding`
    // exists in the error set precisely for this and was unreachable.
    const allocator = testing.allocator;
    const kp = try testKey(@splat(0x11));
    const envelope = try sealForTest(allocator, kp, "product = \"mecha-validate\"\n");
    defer allocator.free(envelope);

    // Sanity: the untouched envelope verifies. Without this the test could
    // pass because the fixture was broken to begin with.
    const ok = try verifyEnvelope(allocator, envelope, &kp.public_key.toBytes());
    allocator.free(ok);

    const intruders = [_][]const u8{
        "\u{2603}", // snowman
        "\u{1F600}", // emoji, 4-byte
        "\u{00E9}", // e-acute, 2-byte
        "\u{4E2D}", // CJK, 3-byte
        "\u{0416}", // Cyrillic Zhe
    };

    for (intruders, 0..) |glyph, i| {
        // Splice the intruder in just after `data`'s opening quote.
        const marker = "{\"data\":\"";
        const at = std.mem.indexOf(u8, envelope, marker) orelse return error.TestUnexpectedResult;
        const cut = at + marker.len;

        var corrupted = std.ArrayList(u8).empty;
        defer corrupted.deinit(allocator);
        try corrupted.appendSlice(allocator, envelope[0..cut]);
        try corrupted.appendSlice(allocator, glyph);
        try corrupted.appendSlice(allocator, envelope[cut..]);

        const r = verifyEnvelope(allocator, corrupted.items, &kp.public_key.toBytes());
        if (r) |payload| {
            allocator.free(payload);
            std.debug.print("intruder {d} was ACCEPTED\n", .{i});
            return error.TestUnexpectedResult;
        } else |e| {
            if (e == EnvelopeError.MalformedEncoding) continue;
            std.debug.print("intruder {d} gave {s}, want MalformedEncoding\n", .{ i, @errorName(e) });
            return error.TestUnexpectedResult;
        }
    }
}

test "specificity: every byte value still round-trips through the alphabet check" {
    // The corpus that stops the fix above from being "reject anything unusual".
    // Every one of the 256 byte values must survive encode -> envelope ->
    // verify; one legitimate glyph misclassified as corruption would make some
    // real licenses permanently unverifiable, which is worse than the bug being
    // fixed.
    const allocator = testing.allocator;
    const kp = try testKey(@splat(0x22));

    var payload: [256]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i);

    const envelope = try sealForTest(allocator, kp, &payload);
    defer allocator.free(envelope);

    const got = try verifyEnvelope(allocator, envelope, &kp.public_key.toBytes());
    defer allocator.free(got);
    try testing.expectEqualSlices(u8, &payload, got);

    // And every single-byte payload alone, so one bad glyph cannot hide among
    // 255 good ones in a single buffer.
    for (0..256) |i| {
        const one = [_]u8{@intCast(i)};
        const env1 = try sealForTest(allocator, kp, &one);
        defer allocator.free(env1);
        const out = verifyEnvelope(allocator, env1, &kp.public_key.toBytes()) catch |e| {
            std.debug.print("byte 0x{X:0>2} rejected as {s}\n", .{ i, @errorName(e) });
            return e;
        };
        defer allocator.free(out);
        try testing.expectEqualSlices(u8, &one, out);
    }
}

test "an unmapped glyph in the sig field is corruption too" {
    // `sig` goes through the same decoder and needs the same classification.
    // Checked separately because a fix applied to only one field would leave
    // this half broken with every existing test still green.
    const allocator = testing.allocator;
    const kp = try testKey(@splat(0x33));
    const envelope = try sealForTest(allocator, kp, "product = \"mecha-validate\"\n");
    defer allocator.free(envelope);

    const marker = "\"sig\":\"";
    const at = std.mem.indexOf(u8, envelope, marker) orelse return error.TestUnexpectedResult;
    const cut = at + marker.len;

    var corrupted = std.ArrayList(u8).empty;
    defer corrupted.deinit(allocator);
    try corrupted.appendSlice(allocator, envelope[0..cut]);
    try corrupted.appendSlice(allocator, "\u{2603}");
    try corrupted.appendSlice(allocator, envelope[cut..]);

    try testing.expectError(
        EnvelopeError.MalformedEncoding,
        verifyEnvelope(allocator, corrupted.items, &kp.public_key.toBytes()),
    );
}
