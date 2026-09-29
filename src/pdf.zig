//! Minimal PDF 1.4 writer: pages of text lines and filled rectangles.
//! Pure: a description in, the file's bytes out. No compression, no font
//! embedding (the standard 14 Type1 fonts: Helvetica, Helvetica-Bold,
//! Courier), so any viewer renders it and any text extractor reads it.
//!
//! Exists for the paper cold copies (custody contract v1.3 (c)): the QR code
//! is vector rectangles, the base64 is real text objects so it can be copied
//! out of the page. Independent oracles: qpdf checks structure, pdftotext
//! proves the text is selectable, pdftoppm + zbar read the QR back.

const std = @import("std");

pub const Font = enum {
    helvetica,
    helvetica_bold,
    courier,

    fn resourceName(self: Font) []const u8 {
        return switch (self) {
            .helvetica => "/F1",
            .helvetica_bold => "/F2",
            .courier => "/F3",
        };
    }
    fn baseFont(self: Font) []const u8 {
        return switch (self) {
            .helvetica => "/Helvetica",
            .helvetica_bold => "/Helvetica-Bold",
            .courier => "/Courier",
        };
    }
};

pub const Text = struct {
    font: Font,
    size: f32,
    /// Baseline origin in points, PDF user space (origin bottom-left).
    x: f32,
    y: f32,
    text: []const u8,
};

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const Page = struct {
    /// US Letter by default.
    width: f32 = 612,
    height: f32 = 792,
    texts: []const Text,
    rects: []const Rect,
};

// ── Writer ─────────────────────────────────────────────────────────────────

const Buf = std.ArrayListUnmanaged(u8);

/// Plain decimal with at most two places and no trailing zeros. PDF has no
/// exponent syntax, and 1/100 pt is finer than any printer resolves.
fn fmtNum(buf: []u8, v: f32) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch unreachable;
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
    }
    if (std.mem.eql(u8, s[0..end], "-0")) return "0";
    return s[0..end];
}

fn putNum(a: std.mem.Allocator, out: *Buf, v: f32) std.mem.Allocator.Error!void {
    var buf: [32]u8 = undefined;
    try out.appendSlice(a, fmtNum(&buf, v));
}

fn putFmt(a: std.mem.Allocator, out: *Buf, comptime f: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, f, args);
    defer a.free(s);
    try out.appendSlice(a, s);
}

/// A PDF literal string: parentheses and backslashes escaped, line ends as
/// escapes so a stray newline in a label cannot break the content stream.
fn putEscaped(a: std.mem.Allocator, out: *Buf, text: []const u8) std.mem.Allocator.Error!void {
    try out.append(a, '(');
    for (text) |c| {
        switch (c) {
            '(', ')', '\\' => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            else => try out.append(a, c),
        }
    }
    try out.append(a, ')');
}

fn contentStream(a: std.mem.Allocator, page: Page) std.mem.Allocator.Error![]u8 {
    var c: Buf = .empty;
    errdefer c.deinit(a);
    for (page.rects) |r| {
        try putNum(a, &c, r.x);
        try c.append(a, ' ');
        try putNum(a, &c, r.y);
        try c.append(a, ' ');
        try putNum(a, &c, r.w);
        try c.append(a, ' ');
        try putNum(a, &c, r.h);
        try c.appendSlice(a, " re\nf\n");
    }
    for (page.texts) |t| {
        try c.appendSlice(a, "BT\n");
        try c.appendSlice(a, t.font.resourceName());
        try c.append(a, ' ');
        try putNum(a, &c, t.size);
        try c.appendSlice(a, " Tf\n");
        try putNum(a, &c, t.x);
        try c.append(a, ' ');
        try putNum(a, &c, t.y);
        try c.appendSlice(a, " Td\n");
        try putEscaped(a, &c, t.text);
        try c.appendSlice(a, " Tj\nET\n");
    }
    return c.toOwnedSlice(a);
}

/// Render pages to a complete PDF 1.4 file. Object numbering: 1 catalog,
/// 2 page tree, 3-5 the fonts, then (page, content) pairs.
pub fn render(a: std.mem.Allocator, pages: []const Page) std.mem.Allocator.Error![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(a);
    const n_objects = 5 + 2 * pages.len;
    const offsets = try a.alloc(usize, n_objects + 1);
    defer a.free(offsets);

    try out.appendSlice(a, "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    offsets[1] = out.items.len;
    try out.appendSlice(a, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    offsets[2] = out.items.len;
    try putFmt(a, &out, "2 0 obj\n<< /Type /Pages /Count {d} /Kids [", .{pages.len});
    for (0..pages.len) |i| {
        if (i != 0) try out.append(a, ' ');
        try putFmt(a, &out, "{d} 0 R", .{6 + 2 * i});
    }
    try out.appendSlice(a, "] >>\nendobj\n");

    const fonts = [_]Font{ .helvetica, .helvetica_bold, .courier };
    for (fonts, 0..) |f, i| {
        offsets[3 + i] = out.items.len;
        try putFmt(a, &out, "{d} 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont {s} /Encoding /WinAnsiEncoding >>\nendobj\n", .{ 3 + i, f.baseFont() });
    }

    for (pages, 0..) |page, i| {
        const page_obj = 6 + 2 * i;
        const content_obj = page_obj + 1;
        offsets[page_obj] = out.items.len;
        try putFmt(a, &out, "{d} 0 obj\n<< /Type /Page\n/Parent 2 0 R\n/MediaBox [0 0 ", .{page_obj});
        try putNum(a, &out, page.width);
        try out.append(a, ' ');
        try putNum(a, &out, page.height);
        try putFmt(a, &out, "]\n/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >>\n/Contents {d} 0 R >>\nendobj\n", .{content_obj});

        const content = try contentStream(a, page);
        defer a.free(content);
        offsets[content_obj] = out.items.len;
        try putFmt(a, &out, "{d} 0 obj\n<< /Length {d} >>\nstream\n", .{ content_obj, content.len });
        try out.appendSlice(a, content);
        try out.appendSlice(a, "\nendstream\nendobj\n");
    }

    const xref_at = out.items.len;
    try putFmt(a, &out, "xref\n0 {d}\n0000000000 65535 f \n", .{n_objects + 1});
    for (1..n_objects + 1) |n| {
        try putFmt(a, &out, "{d:0>10} 00000 n \n", .{offsets[n]});
    }
    try putFmt(a, &out, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ n_objects + 1, xref_at });
    return out.toOwnedSlice(a);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const one_page = [_]Page{.{
    .texts = &.{
        .{ .font = .helvetica_bold, .size = 14, .x = 72, .y = 720, .text = "Title (with) parens \\ and backslash" },
        .{ .font = .courier, .size = 9, .x = 72, .y = 700, .text = "QUJDREVGR0g=" },
    },
    .rects = &.{
        .{ .x = 72, .y = 400, .w = 3.14159, .h = 3.14159 },
        .{ .x = 75.5, .y = 400, .w = 3, .h = 3 },
    },
}};

fn findAll(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, hay, at, needle)) |i| : (at = i + needle.len) n += 1;
    return n;
}

test "the file has the PDF 1.4 header and the EOF marker" {
    const a = testing.allocator;
    const pdf = try render(a, &one_page);
    defer a.free(pdf);
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4\n"));
    try testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
}

test "startxref points at the xref table and every entry points at its object" {
    const a = testing.allocator;
    const pdf = try render(a, &one_page);
    defer a.free(pdf);

    const sx = std.mem.lastIndexOf(u8, pdf, "startxref\n") orelse return error.TestUnexpectedResult;
    const digits_end = std.mem.indexOfScalarPos(u8, pdf, sx + 10, '\n') orelse return error.TestUnexpectedResult;
    const xref_at = try std.fmt.parseInt(usize, pdf[sx + 10 .. digits_end], 10);
    try testing.expect(std.mem.startsWith(u8, pdf[xref_at..], "xref\n"));

    // "xref\n0 N\n" then N 20-byte entries.
    const hdr_end = std.mem.indexOfScalarPos(u8, pdf, xref_at + 5, '\n') orelse return error.TestUnexpectedResult;
    var it = std.mem.splitScalar(u8, pdf[xref_at + 5 .. hdr_end], ' ');
    _ = it.next();
    const count = try std.fmt.parseInt(usize, it.next().?, 10);
    try testing.expect(count >= 6);
    try testing.expectEqualStrings("0000000000 65535 f \n", pdf[hdr_end + 1 .. hdr_end + 21]);
    for (1..count) |n| {
        const entry = pdf[hdr_end + 1 + n * 20 .. hdr_end + 1 + (n + 1) * 20];
        const offset = try std.fmt.parseInt(usize, entry[0..10], 10);
        var want: [16]u8 = undefined;
        const head = try std.fmt.bufPrint(&want, "{d} 0 obj\n", .{n});
        testing.expect(std.mem.startsWith(u8, pdf[offset..], head)) catch |e| {
            std.debug.print("xref entry {d} -> offset {d} reads {s}\n", .{ n, offset, pdf[offset..@min(pdf.len, offset + 12)] });
            return e;
        };
    }
    // The trailer names the object count and the catalog.
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Catalog") != null);
    var size_buf: [16]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, pdf, try std.fmt.bufPrint(&size_buf, "/Size {d}", .{count})) != null);
}

test "the page tree counts every page" {
    const a = testing.allocator;
    const two = [_]Page{ one_page[0], one_page[0] };
    const pdf = try render(a, &two);
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Type /Pages") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Count 2") != null);
    try testing.expectEqual(@as(usize, 2), findAll(pdf, "/Type /Page\n"));
    try testing.expect(std.mem.indexOf(u8, pdf, "/MediaBox [0 0 612 792]") != null);
}

test "each content stream's /Length is exact" {
    const a = testing.allocator;
    const pdf = try render(a, &one_page);
    defer a.free(pdf);
    var at: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, pdf, at, "/Length ")) |i| : (seen += 1) {
        const end = std.mem.indexOfAnyPos(u8, pdf, i + 8, " >\n") orelse return error.TestUnexpectedResult;
        const len = try std.fmt.parseInt(usize, pdf[i + 8 .. end], 10);
        const s = std.mem.indexOfPos(u8, pdf, end, "stream\n") orelse return error.TestUnexpectedResult;
        const body_start = s + 7;
        try testing.expectEqualStrings("\nendstream", pdf[body_start + len .. body_start + len + 10]);
        at = body_start + len;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "text is emitted as escaped string operators in the named font" {
    const a = testing.allocator;
    const pdf = try render(a, &one_page);
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, "/F2 14 Tf") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "(Title \\(with\\) parens \\\\ and backslash) Tj") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/F3 9 Tf") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "(QUJDREVGR0g=) Tj") != null);
    // The three standard fonts are declared once each, unembedded.
    try testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Encoding /WinAnsiEncoding") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/FontFile") == null);
}

test "rectangles are filled paths with plain decimal coordinates" {
    const a = testing.allocator;
    const pdf = try render(a, &one_page);
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, "72 400 3.14 3.14 re\nf\n") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "75.5 400 3 3 re\nf\n") != null);
    // PDF has no exponent syntax, and nothing here should need more than two
    // decimals.
    try testing.expect(std.mem.indexOf(u8, pdf, "e+") == null);
    try testing.expect(std.mem.indexOf(u8, pdf, "e-") == null);
}

test "number formatting drops needless zeros and never uses exponents" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("612", fmtNum(&buf, 612));
    try testing.expectEqualStrings("3.14", fmtNum(&buf, 3.14159));
    try testing.expectEqualStrings("75.5", fmtNum(&buf, 75.5));
    try testing.expectEqualStrings("0.1", fmtNum(&buf, 0.1));
    try testing.expectEqualStrings("0", fmtNum(&buf, 0.001));
}
