//! Paper cold copies: a sealed keyfile or hot bundle as a printable page.
//! Custody contract v1.3 (c), Peter 2026-09-28: a QR code in a PDF, the
//! text form printed as real text so it can be copied out, and text on the
//! page saying what the artifact is. The text form is uppercase hex (Peter
//! 2026-10-06, walking brief I2): 64 digits per line in groups of 8. Pure: bytes and labels in, PDF bytes out; the
//! date is a parameter, never a clock read.
//!
//! The QR and the text carry the SAME hex digits of the sealed bytes (the QR
//! without the spaces), so either restores the file: hex-decoding the scan
//! or the typed text, whitespace ignored, yields the artifact byte for byte. The artifact is already passphrase-encrypted, so
//! paper needs no second secret and is inert without the passphrase.

const std = @import("std");
const qr = @import("qr.zig");
const pdf = @import("pdf.zig");

pub const Kind = enum { keyfile, hot_bundle };

pub const Artifact = struct {
    kind: Kind,
    /// Human identification, e.g. "Mecha Validate beta-license".
    label: []const u8,
    /// The file name the bytes restore to, e.g. "validate_beta.key".
    filename: []const u8,
    bytes: []const u8,
    /// The matching public key, printed as hex when known (the `.pub` text
    /// form is UTF-8 printable-binary, which a WinAnsi PDF font cannot show).
    pubkey: ?[32]u8 = null,
};

pub const Meta = struct {
    /// YYYY-MM-DD, supplied by the caller.
    date: []const u8,
    sigil_version: []const u8,
};

pub const Error = error{ OutOfMemory, DataTooLong };

// ── Layout ─────────────────────────────────────────────────────────────────

const page_w: f32 = 612;
const page_h: f32 = 792;
const margin: f32 = 54;
/// Courier 9 pt is 5.4 pt per glyph; 92 of them fit the 504 pt text width
/// with room to spare, and Helvetica 9 is narrower still.
pub const max_line_chars: usize = 92;
const title_max_chars: usize = 60;
/// Hex digits per printed line, shown as 8 groups of 8 for typing.
const hex_cols: usize = 64;
const hex_group: usize = 8;
/// Medium error correction: a scanner still reads a page with a coffee ring
/// on it, and the artifacts are small enough that the code stays modest.
pub const qr_level: qr.EcLevel = .M;
const qr_side: f32 = 252;

const Texts = std.ArrayListUnmanaged(pdf.Text);
const Rects = std.ArrayListUnmanaged(pdf.Rect);

const Cursor = struct {
    y: f32,
    texts: *Texts,
    arena: std.mem.Allocator,

    fn line(self: *Cursor, font: pdf.Font, size: f32, leading: f32, text: []const u8) Error!void {
        try self.texts.append(self.arena, .{ .font = font, .size = size, .x = margin, .y = self.y, .text = text });
        self.y -= leading;
    }

    /// Greedy word wrap at `max` characters; a single overlong word is split.
    fn paragraph(self: *Cursor, font: pdf.Font, size: f32, leading: f32, text: []const u8, max: usize) Error!void {
        var start: usize = 0;
        while (start < text.len) {
            var end = @min(text.len, start + max);
            if (end < text.len) {
                if (std.mem.lastIndexOfScalar(u8, text[start..end], ' ')) |sp| {
                    if (sp > 0) end = start + sp;
                }
            }
            try self.line(font, size, leading, text[start..end]);
            start = end;
            while (start < text.len and text[start] == ' ') start += 1;
        }
    }

    fn gap(self: *Cursor, pts: f32) void {
        self.y -= pts;
    }
};

fn kindNoun(kind: Kind) []const u8 {
    return switch (kind) {
        .keyfile => "keyfile",
        .hot_bundle => "hot bundle",
    };
}

fn composePage(arena: std.mem.Allocator, art: Artifact, meta: Meta, digits: []const u8, code: qr.Code) Error!pdf.Page {
    const texts = try arena.create(Texts);
    texts.* = .empty;
    const rects = try arena.create(Rects);
    rects.* = .empty;
    var c = Cursor{ .y = page_h - margin, .texts = texts, .arena = arena };

    // Identification.
    const title = try std.fmt.allocPrint(arena, "sigil cold copy: {s}", .{art.label});
    try c.paragraph(.helvetica_bold, 15, 18, title, title_max_chars);
    const subtitle = switch (art.kind) {
        .keyfile => "Sealed signing keyfile (Argon2id + XChaCha20-Poly1305). Inert without its passphrase.",
        .hot_bundle => "Sealed hot bundle: PKCS#8 for restore-to-online. Inert without its passphrase.",
    };
    try c.line(.helvetica, 11, 16, subtitle);
    c.gap(4);

    // Purpose and restore instructions.
    const purpose = switch (art.kind) {
        .keyfile => try std.fmt.allocPrint(arena, "This page is a cold copy of the {s} signing keyfile. The bytes are encrypted at rest under the key's passphrase, so the page is useless to anyone without it. To restore: scan the QR code, or type the text form below, and hex-decode it into a file named {s}; spaces and line breaks are ignored. The decoded file must have the SHA-256 shown here.", .{ art.label, art.filename }),
        .hot_bundle => try std.fmt.allocPrint(arena, "This page is a cold copy of the {s} hot bundle, the sealed PKCS#8 form of the same key, made at generation for putting the key back into the online issuer. The bytes are encrypted at rest under the key's passphrase, so the page is useless to anyone without it. To restore: scan the QR code, or type the text form below, and hex-decode it into a file named {s}; spaces and line breaks are ignored. The decoded file must have the SHA-256 shown here.", .{ art.label, art.filename }),
    };
    try c.paragraph(.helvetica, 9, 11.5, purpose, max_line_chars);
    try c.line(.helvetica, 9, 11.5, "Decode the typed text (Linux, then macOS):");
    try c.paragraph(.courier, 9, 11.5, try std.fmt.allocPrint(arena, "tr -d ' \\n' < typed.txt | basenc --base16 -d > {s}", .{art.filename}), max_line_chars);
    try c.paragraph(.courier, 9, 11.5, try std.fmt.allocPrint(arena, "xxd -r -p typed.txt > {s}", .{art.filename}), max_line_chars);
    try c.line(.helvetica, 9, 11.5, switch (art.kind) {
        .keyfile => "Then sign with:",
        .hot_bundle => "Then, and only through a pipe, never into a file:",
    });
    const command = switch (art.kind) {
        .keyfile => try std.fmt.allocPrint(arena, "sigil sign --key {s} <payload>", .{art.filename}),
        .hot_bundle => try std.fmt.allocPrint(arena, "sigil hot-bundle open {s} | wrangler secret put SIGNING_KEY_<ROLE>", .{art.filename}),
    };
    try c.paragraph(.courier, 9, 11.5, command, max_line_chars);
    c.gap(6);

    // Metadata.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(art.bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try c.line(.courier, 9, 11.5, try std.fmt.allocPrint(arena, "Created {s} with sigil {s}", .{ meta.date, meta.sigil_version }));
    try c.line(.courier, 9, 11.5, try std.fmt.allocPrint(arena, "Artifact {s} ({d} bytes, a sigil {s})", .{ art.filename, art.bytes.len, kindNoun(art.kind) }));
    try c.line(.courier, 9, 11.5, try std.fmt.allocPrint(arena, "SHA-256 {s}", .{&hex}));
    if (art.pubkey) |pk| {
        const pk_hex = std.fmt.bytesToHex(pk, .lower);
        try c.line(.courier, 9, 11.5, try std.fmt.allocPrint(arena, "Public key (hex) {s}", .{&pk_hex}));
    }
    c.gap(10);

    // The QR code: one rectangle per horizontal run of dark modules, top row
    // first. The page's white around it is the quiet zone.
    const module: f32 = qr_side / @as(f32, @floatFromInt(code.size));
    const top = c.y;
    for (0..code.size) |row| {
        var x: usize = 0;
        while (x < code.size) {
            if (!code.get(x, row)) {
                x += 1;
                continue;
            }
            const start = x;
            while (x < code.size and code.get(x, row)) x += 1;
            try rects.append(arena, .{
                .x = margin + @as(f32, @floatFromInt(start)) * module,
                .y = top - @as(f32, @floatFromInt(row + 1)) * module,
                .w = @as(f32, @floatFromInt(x - start)) * module,
                .h = module,
            });
        }
    }
    c.y = top - qr_side;
    c.gap(18);

    // The text form: 64 uppercase hex digits per line in groups of 8.
    try c.line(.helvetica, 9, 12, "Text form (hex, 8 groups of 8 per line; the QR holds the same digits, no spaces):");
    var at: usize = 0;
    while (at < digits.len) : (at += hex_cols) {
        try c.line(.courier, 9, 11, try groupDigits(arena, digits[at..@min(digits.len, at + hex_cols)]));
    }

    return .{ .width = page_w, .height = page_h, .texts = texts.items, .rects = rects.items };
}

/// Uppercase hex: decodable by coreutils `basenc --base16 -d` (which rejects
/// lowercase) and by `xxd -r -p`, and unambiguous to read aloud or retype.
fn upperHex(arena: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const out = try arena.alloc(u8, bytes.len * 2);
    const table = "0123456789ABCDEF";
    for (bytes, 0..) |b, i| {
        out[2 * i] = table[b >> 4];
        out[2 * i + 1] = table[b & 0x0f];
    }
    return out;
}

/// One printed line: the digits split into space-separated groups of
/// `hex_group` so a person retyping the page keeps their place.
fn groupDigits(arena: std.mem.Allocator, digits: []const u8) Error![]u8 {
    const groups = (digits.len + hex_group - 1) / hex_group;
    const out = try arena.alloc(u8, digits.len + groups -| 1);
    var n: usize = 0;
    for (digits, 0..) |d, i| {
        if (i > 0 and i % hex_group == 0) {
            out[n] = ' ';
            n += 1;
        }
        out[n] = d;
        n += 1;
    }
    return out[0..n];
}

/// One page per artifact, in order.
pub fn render(allocator: std.mem.Allocator, artifacts: []const Artifact, meta: Meta) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pages: std.ArrayListUnmanaged(pdf.Page) = .empty;
    for (artifacts) |art| {
        const digits = try upperHex(arena, art.bytes);
        var code = try qr.encodeBytes(arena, digits, qr_level);
        defer code.deinit();
        try pages.append(arena, try composePage(arena, art, meta, digits, code));
    }
    return pdf.render(allocator, pages.items);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const sample_bytes = "{\"sigil\":\"secret-key-v1\",\"kdf\":\"Argon2id\",\"t\":3,\"m\":65536,\"p\":1,\"salt\":\"abc\",\"nonce\":\"def\",\"ciphertext\":\"ghi\"}\n";
const sample_meta: Meta = .{ .date = "2026-09-28", .sigil_version = "0.1.0" };

fn sampleKeyfile() Artifact {
    return .{
        .kind = .keyfile,
        .label = "Mecha Validate beta-license (TEST)",
        .filename = "validate_beta.key",
        .bytes = sample_bytes,
        .pubkey = [_]u8{0xAB} ** 16 ++ [_]u8{0xCD} ** 16,
    };
}

fn sampleBundle() Artifact {
    return .{
        .kind = .hot_bundle,
        .label = "Mecha Validate beta-license (TEST)",
        .filename = "validate_beta.hot.sealed",
        .bytes = sample_bytes,
    };
}

fn countTj(pdf_bytes: []const u8, text: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, pdf_bytes, at, text)) |i| : (at = i + text.len) {
        if (std.mem.startsWith(u8, pdf_bytes[i + text.len ..], ") Tj")) n += 1;
    }
    return n;
}

test "the page names the artifact: label, file, kind, date, version, SHA-256" {
    const a = testing.allocator;
    const out = try render(a, &.{sampleKeyfile()}, sample_meta);
    defer a.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Mecha Validate beta-license \\(TEST\\)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "validate_beta.key") != null);
    try testing.expect(std.mem.indexOf(u8, out, "keyfile") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2026-09-28") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sigil 0.1.0") != null);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sample_bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out, &hex) != null);
    try testing.expect(std.mem.indexOf(u8, out, "Public key \\(hex\\) " ++ "ab" ** 16 ++ "cd" ** 16) != null);
}

/// Uppercase hex of `bytes`, the exact digits the QR code carries. Test helper.
fn testHex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try a.alloc(u8, bytes.len * 2);
    const digits = "0123456789ABCDEF";
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return out;
}

test "the hex lines are 64 uppercase digits in groups of 8 and decode to the bytes" {
    const a = testing.allocator;
    const out = try render(a, &.{sampleKeyfile()}, sample_meta);
    defer a.free(out);

    const hex = try testHex(a, sample_bytes);
    defer a.free(hex);
    var at: usize = 0;
    var lines: usize = 0;
    var grouped: [64 + 7]u8 = undefined;
    while (at < hex.len) : (at += 64) {
        const digits = hex[at..@min(hex.len, at + 64)];
        var n: usize = 0;
        for (digits, 0..) |d, i| {
            if (i > 0 and i % 8 == 0) {
                grouped[n] = ' ';
                n += 1;
            }
            grouped[n] = d;
            n += 1;
        }
        testing.expectEqual(@as(usize, 1), countTj(out, grouped[0..n])) catch |e| {
            std.debug.print("hex line not found exactly once: {s}\n", .{grouped[0..n]});
            return e;
        };
        lines += 1;
    }
    try testing.expect(lines >= 3);
    // No base64 form remains on the page.
    try testing.expect(std.mem.indexOf(u8, out, "base64") == null);
}

test "restore instructions match the kind" {
    const a = testing.allocator;
    const key_page = try render(a, &.{sampleKeyfile()}, sample_meta);
    defer a.free(key_page);
    try testing.expect(std.mem.indexOf(u8, key_page, "sigil sign --key validate_beta.key") != null);
    try testing.expect(std.mem.indexOf(u8, key_page, "wrangler") == null);
    try testing.expect(std.mem.indexOf(u8, key_page, "hex-decode") != null);
    try testing.expect(std.mem.indexOf(u8, key_page, "basenc --base16 -d > validate_beta.key") != null);
    try testing.expect(std.mem.indexOf(u8, key_page, "xxd -r -p typed.txt > validate_beta.key") != null);

    const bundle_page = try render(a, &.{sampleBundle()}, sample_meta);
    defer a.free(bundle_page);
    try testing.expect(std.mem.indexOf(u8, bundle_page, "sigil hot-bundle open validate_beta.hot.sealed | wrangler secret put") != null);
    try testing.expect(std.mem.indexOf(u8, bundle_page, "hot bundle") != null);
    try testing.expect(std.mem.indexOf(u8, bundle_page, "Public key") == null);
}

test "one page per artifact" {
    const a = testing.allocator;
    const out = try render(a, &.{ sampleKeyfile(), sampleBundle() }, sample_meta);
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "/Count 2") != null);
}

test "the QR carries exactly the hex digits without spaces, drawn as one rectangle per dark run" {
    const a = testing.allocator;
    const out = try render(a, &.{sampleKeyfile()}, sample_meta);
    defer a.free(out);

    const hex = try testHex(a, sample_bytes);
    defer a.free(hex);
    var code = try qr.encodeBytes(a, hex, qr_level);
    defer code.deinit();

    var runs: usize = 0;
    for (0..code.size) |y| {
        var x: usize = 0;
        while (x < code.size) {
            if (code.get(x, y)) {
                runs += 1;
                while (x < code.size and code.get(x, y)) x += 1;
            } else x += 1;
        }
    }
    var rects: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, out, at, " re\nf\n")) |i| : (at = i + 6) rects += 1;
    try testing.expectEqual(runs, rects);
}

test "text never runs past the printable width" {
    const a = testing.allocator;
    const long = Artifact{
        .kind = .hot_bundle,
        .label = "A label long enough that the purpose paragraph must wrap onto several lines to stay inside the margins of the page",
        .filename = "a_rather_long_artifact_file_name_for_wrapping.hot.sealed",
        .bytes = sample_bytes,
    };
    const out = try render(a, &.{long}, sample_meta);
    defer a.free(out);
    var it = std.mem.splitSequence(u8, out, ") Tj");
    while (it.next()) |chunk| {
        const open = std.mem.lastIndexOfScalar(u8, chunk, '(') orelse continue;
        try testing.expect(chunk.len - open - 1 <= max_line_chars);
    }
}

test "nothing is drawn below the bottom margin for artifacts of the real size" {
    // A sealed keyfile or hot bundle is under 300 bytes (measured: 255-272
    // for keyfiles, 290 for a hot bundle); 500 leaves 70% headroom. Every
    // text baseline and every rectangle stays above the margin.
    const a = testing.allocator;
    const big = "x" ** 500;
    const out = try render(a, &.{.{ .kind = .hot_bundle, .label = "fit", .filename = "fit.hot.sealed", .bytes = big, .pubkey = [_]u8{1} ** 32 }}, sample_meta);
    defer a.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |ln| {
        if (std.mem.endsWith(u8, ln, " Td") or std.mem.endsWith(u8, ln, " re")) {
            var parts = std.mem.splitScalar(u8, ln, ' ');
            _ = parts.next();
            const y = try std.fmt.parseFloat(f32, parts.next().?);
            testing.expect(y >= margin) catch |e| {
                std.debug.print("below margin: {s}\n", .{ln});
                return e;
            };
        }
    }
}
