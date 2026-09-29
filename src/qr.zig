//! QR code encoder, cleanroom, byte mode, all 40 versions and 4 EC levels.
//! Pure: bytes in, module matrix out; no I/O, no allocation beyond the matrix.
//!
//! Exists for the paper cold copies (custody contract v1.3 (c)): a sealed
//! keyfile or hot bundle rendered as a QR code in a PDF. ISO/IEC 18004
//! throughout; the independent oracle is zbar decoding poppler's raster of
//! the finished page (tests/cli/test_cli), never this file's own reading.
//!
//! Technique: Reed-Solomon over GF(2^8) with the 0x11D primitive, block
//! interleaving per the version/EC table, zigzag placement, all eight masks
//! scored by the four penalty rules, BCH-protected format and version fields.

const std = @import("std");

pub const EcLevel = enum(u2) {
    // Bit values as they appear in the format information.
    M = 0,
    L = 1,
    H = 2,
    Q = 3,
};

pub const Error = error{ DataTooLong, OutOfMemory };

pub const Code = struct {
    version: u8,
    size: u16,
    /// Row-major, one byte per module, 1 = dark.
    modules: []u8,
    allocator: std.mem.Allocator,

    pub fn get(self: Code, x: usize, y: usize) bool {
        return self.modules[y * self.size + x] == 1;
    }

    pub fn deinit(self: *Code) void {
        self.allocator.free(self.modules);
        self.* = undefined;
    }
};

// ── Specification tables ───────────────────────────────────────────────────

/// Total codewords per version 1..40. Independent of the block table below;
/// the test suite checks every block row sums to this.
const total_codewords = [40]u16{
    26,   44,   70,   100,  134,  172,  196,  242,  292,  346,
    404,  466,  532,  581,  655,  733,  815,  901,  991,  1085,
    1156, 1258, 1364, 1474, 1588, 1706, 1828, 1921, 2051, 2185,
    2323, 2465, 2611, 2761, 2876, 3034, 3196, 3362, 3532, 3706,
};

const BlockInfo = struct {
    ec_per_block: u8,
    g1_blocks: u8,
    g1_data: u16,
    g2_blocks: u8,
    g2_data: u16,
};

fn bi(ec: u8, g1b: u8, g1d: u16, g2b: u8, g2d: u16) BlockInfo {
    return .{ .ec_per_block = ec, .g1_blocks = g1b, .g1_data = g1d, .g2_blocks = g2b, .g2_data = g2d };
}

/// Per version, rows in the order L, M, Q, H: EC codewords per block, group 1
/// (blocks, data codewords each), group 2 (blocks, data codewords each).
const block_table = [40][4]BlockInfo{
    .{ bi(7, 1, 19, 0, 0), bi(10, 1, 16, 0, 0), bi(13, 1, 13, 0, 0), bi(17, 1, 9, 0, 0) },
    .{ bi(10, 1, 34, 0, 0), bi(16, 1, 28, 0, 0), bi(22, 1, 22, 0, 0), bi(28, 1, 16, 0, 0) },
    .{ bi(15, 1, 55, 0, 0), bi(26, 1, 44, 0, 0), bi(18, 2, 17, 0, 0), bi(22, 2, 13, 0, 0) },
    .{ bi(20, 1, 80, 0, 0), bi(18, 2, 32, 0, 0), bi(26, 2, 24, 0, 0), bi(16, 4, 9, 0, 0) },
    .{ bi(26, 1, 108, 0, 0), bi(24, 2, 43, 0, 0), bi(18, 2, 15, 2, 16), bi(22, 2, 11, 2, 12) },
    .{ bi(18, 2, 68, 0, 0), bi(16, 4, 27, 0, 0), bi(24, 4, 19, 0, 0), bi(28, 4, 15, 0, 0) },
    .{ bi(20, 2, 78, 0, 0), bi(18, 4, 31, 0, 0), bi(18, 2, 14, 4, 15), bi(26, 4, 13, 1, 14) },
    .{ bi(24, 2, 97, 0, 0), bi(22, 2, 38, 2, 39), bi(22, 4, 18, 2, 19), bi(26, 4, 14, 2, 15) },
    .{ bi(30, 2, 116, 0, 0), bi(22, 3, 36, 2, 37), bi(20, 4, 16, 4, 17), bi(24, 4, 12, 4, 13) },
    .{ bi(18, 2, 68, 2, 69), bi(26, 4, 43, 1, 44), bi(24, 6, 19, 2, 20), bi(28, 6, 15, 2, 16) },
    .{ bi(20, 4, 81, 0, 0), bi(30, 1, 50, 4, 51), bi(28, 4, 22, 4, 23), bi(24, 3, 12, 8, 13) },
    .{ bi(24, 2, 92, 2, 93), bi(22, 6, 36, 2, 37), bi(26, 4, 20, 6, 21), bi(28, 7, 14, 4, 15) },
    .{ bi(26, 4, 107, 0, 0), bi(22, 8, 37, 1, 38), bi(24, 8, 20, 4, 21), bi(22, 12, 11, 4, 12) },
    .{ bi(30, 3, 115, 1, 116), bi(24, 4, 40, 5, 41), bi(20, 11, 16, 5, 17), bi(24, 11, 12, 5, 13) },
    .{ bi(22, 5, 87, 1, 88), bi(24, 5, 41, 5, 42), bi(30, 5, 24, 7, 25), bi(24, 11, 12, 7, 13) },
    .{ bi(24, 5, 98, 1, 99), bi(28, 7, 45, 3, 46), bi(24, 15, 19, 2, 20), bi(30, 3, 15, 13, 16) },
    .{ bi(28, 1, 107, 5, 108), bi(28, 10, 46, 1, 47), bi(28, 1, 22, 15, 23), bi(28, 2, 14, 17, 15) },
    .{ bi(30, 5, 120, 1, 121), bi(26, 9, 43, 4, 44), bi(28, 17, 22, 1, 23), bi(28, 2, 14, 19, 15) },
    .{ bi(28, 3, 113, 4, 114), bi(26, 3, 44, 11, 45), bi(26, 17, 21, 4, 22), bi(26, 9, 13, 16, 14) },
    .{ bi(28, 3, 107, 5, 108), bi(26, 3, 41, 13, 42), bi(30, 15, 24, 5, 25), bi(28, 15, 15, 10, 16) },
    .{ bi(28, 4, 116, 4, 117), bi(26, 17, 42, 0, 0), bi(28, 17, 22, 6, 23), bi(30, 19, 16, 6, 17) },
    .{ bi(28, 2, 111, 7, 112), bi(28, 17, 46, 0, 0), bi(30, 7, 24, 16, 25), bi(24, 34, 13, 0, 0) },
    .{ bi(30, 4, 121, 5, 122), bi(28, 4, 47, 14, 48), bi(30, 11, 24, 14, 25), bi(30, 16, 15, 14, 16) },
    .{ bi(30, 6, 117, 4, 118), bi(28, 6, 45, 14, 46), bi(30, 11, 24, 16, 25), bi(30, 30, 16, 2, 17) },
    .{ bi(26, 8, 106, 4, 107), bi(28, 8, 47, 13, 48), bi(30, 7, 24, 22, 25), bi(30, 22, 15, 13, 16) },
    .{ bi(28, 10, 114, 2, 115), bi(28, 19, 46, 4, 47), bi(28, 28, 22, 6, 23), bi(30, 33, 16, 4, 17) },
    .{ bi(30, 8, 122, 4, 123), bi(28, 22, 45, 3, 46), bi(30, 8, 23, 26, 24), bi(30, 12, 15, 28, 16) },
    .{ bi(30, 3, 117, 10, 118), bi(28, 3, 45, 23, 46), bi(30, 4, 24, 31, 25), bi(30, 11, 15, 31, 16) },
    .{ bi(30, 7, 116, 7, 117), bi(28, 21, 45, 7, 46), bi(30, 1, 23, 37, 24), bi(30, 19, 15, 26, 16) },
    .{ bi(30, 5, 115, 10, 116), bi(28, 19, 47, 10, 48), bi(30, 15, 24, 25, 25), bi(30, 23, 15, 25, 16) },
    .{ bi(30, 13, 115, 3, 116), bi(28, 2, 46, 29, 47), bi(30, 42, 24, 1, 25), bi(30, 23, 15, 28, 16) },
    .{ bi(30, 17, 115, 0, 0), bi(28, 10, 46, 23, 47), bi(30, 10, 24, 35, 25), bi(30, 19, 15, 35, 16) },
    .{ bi(30, 17, 115, 1, 116), bi(28, 14, 46, 21, 47), bi(30, 29, 24, 19, 25), bi(30, 11, 15, 46, 16) },
    .{ bi(30, 13, 115, 6, 116), bi(28, 14, 46, 23, 47), bi(30, 44, 24, 7, 25), bi(30, 59, 16, 1, 17) },
    .{ bi(30, 12, 121, 7, 122), bi(28, 12, 47, 26, 48), bi(30, 39, 24, 14, 25), bi(30, 22, 15, 41, 16) },
    .{ bi(30, 6, 121, 14, 122), bi(28, 6, 47, 34, 48), bi(30, 46, 24, 10, 25), bi(30, 2, 15, 64, 16) },
    .{ bi(30, 17, 122, 4, 123), bi(28, 29, 46, 14, 47), bi(30, 49, 24, 10, 25), bi(30, 24, 15, 46, 16) },
    .{ bi(30, 4, 122, 18, 123), bi(28, 13, 46, 32, 47), bi(30, 48, 24, 14, 25), bi(30, 42, 15, 32, 16) },
    .{ bi(30, 20, 117, 4, 118), bi(28, 40, 47, 7, 48), bi(30, 43, 24, 22, 25), bi(30, 10, 15, 67, 16) },
    .{ bi(30, 19, 118, 6, 119), bi(28, 18, 47, 31, 48), bi(30, 34, 24, 34, 25), bi(30, 20, 15, 61, 16) },
};

fn levelIndex(level: EcLevel) usize {
    return switch (level) {
        .L => 0,
        .M => 1,
        .Q => 2,
        .H => 3,
    };
}

fn blockInfo(version: u8, level: EcLevel) BlockInfo {
    return block_table[version - 1][levelIndex(level)];
}

fn dataCodewords(version: u8, level: EcLevel) u16 {
    const b = blockInfo(version, level);
    return @as(u16, b.g1_blocks) * b.g1_data + @as(u16, b.g2_blocks) * b.g2_data;
}

/// Character-count field width for byte mode.
fn countBits(version: u8) u5 {
    return if (version <= 9) 8 else 16;
}

/// How many payload bytes a version/level pair holds in byte mode.
fn byteCapacity(version: u8, level: EcLevel) usize {
    const bits: usize = @as(usize, dataCodewords(version, level)) * 8 - 4 - countBits(version);
    return bits / 8;
}

/// Row/column centres of the alignment patterns; version 1 has none.
fn alignmentCentres(version: u8) []const u8 {
    return alignment_table[version - 1];
}

const alignment_table = [40][]const u8{
    &.{},
    &.{ 6, 18 },
    &.{ 6, 22 },
    &.{ 6, 26 },
    &.{ 6, 30 },
    &.{ 6, 34 },
    &.{ 6, 22, 38 },
    &.{ 6, 24, 42 },
    &.{ 6, 26, 46 },
    &.{ 6, 28, 50 },
    &.{ 6, 30, 54 },
    &.{ 6, 32, 58 },
    &.{ 6, 34, 62 },
    &.{ 6, 26, 46, 66 },
    &.{ 6, 26, 48, 70 },
    &.{ 6, 26, 50, 74 },
    &.{ 6, 30, 54, 78 },
    &.{ 6, 30, 56, 82 },
    &.{ 6, 30, 58, 86 },
    &.{ 6, 34, 62, 90 },
    &.{ 6, 28, 50, 72, 94 },
    &.{ 6, 26, 50, 74, 98 },
    &.{ 6, 30, 54, 78, 102 },
    &.{ 6, 28, 54, 80, 106 },
    &.{ 6, 32, 58, 84, 110 },
    &.{ 6, 30, 58, 86, 114 },
    &.{ 6, 34, 62, 90, 118 },
    &.{ 6, 26, 50, 74, 98, 122 },
    &.{ 6, 30, 54, 78, 102, 126 },
    &.{ 6, 26, 52, 78, 104, 130 },
    &.{ 6, 30, 56, 82, 108, 134 },
    &.{ 6, 34, 60, 86, 112, 138 },
    &.{ 6, 30, 58, 86, 114, 142 },
    &.{ 6, 34, 62, 90, 118, 146 },
    &.{ 6, 30, 54, 78, 102, 126, 150 },
    &.{ 6, 24, 50, 76, 102, 128, 154 },
    &.{ 6, 28, 54, 80, 106, 132, 158 },
    &.{ 6, 32, 58, 84, 110, 136, 162 },
    &.{ 6, 26, 54, 82, 110, 138, 166 },
    &.{ 6, 30, 58, 86, 114, 142, 170 },
};

// ── GF(2^8) and Reed-Solomon ───────────────────────────────────────────────

const gf_exp = blk: {
    @setEvalBranchQuota(4000);
    var t: [512]u8 = undefined;
    var x: u16 = 1;
    for (0..255) |i| {
        t[i] = @intCast(x);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    for (255..512) |i| t[i] = t[i - 255];
    break :blk t;
};

const gf_log = blk: {
    @setEvalBranchQuota(4000);
    var t: [256]u8 = undefined;
    t[0] = 0;
    for (0..255) |i| t[gf_exp[i]] = @intCast(i);
    break :blk t;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + gf_log[b]];
}

/// The largest EC codeword count any block uses.
const rs_max_ec = 30;

/// Generator polynomial with `n` roots α^0..α^(n-1), integer coefficients,
/// highest degree first.
fn rsGenerator(buf: *[rs_max_ec + 1]u8, n: usize) []u8 {
    buf[0] = 1;
    var len: usize = 1;
    for (0..n) |i| {
        const root = gf_exp[i];
        buf[len] = 0;
        var j: usize = len;
        while (j > 0) : (j -= 1) {
            buf[j] ^= gfMul(buf[j - 1], root);
        }
        len += 1;
    }
    return buf[0..len];
}

/// Systematic Reed-Solomon: `ec` receives the remainder of data·x^n mod g(x).
fn rsEncode(data: []const u8, ec: []u8) void {
    var gen_buf: [rs_max_ec + 1]u8 = undefined;
    const gen = rsGenerator(&gen_buf, ec.len);
    const n = ec.len;
    @memset(ec, 0);
    for (data) |d| {
        const factor = d ^ ec[0];
        std.mem.copyForwards(u8, ec[0 .. n - 1], ec[1..n]);
        ec[n - 1] = 0;
        if (factor != 0) {
            for (0..n) |j| ec[j] ^= gfMul(gen[j + 1], factor);
        }
    }
}

// ── BCH-protected format and version fields ────────────────────────────────

fn bchRemainder(value: u32, poly: u32, poly_bits: u5, total_bits: u5) u32 {
    var v = value << (poly_bits - 1);
    var i: u5 = total_bits - 1;
    while (true) : (i -= 1) {
        if ((v >> i) & 1 != 0) v ^= poly << (i - (poly_bits - 1));
        if (i == poly_bits - 1) break;
    }
    return v;
}

fn formatBits(level: EcLevel, mask: u3) u15 {
    const data: u32 = (@as(u32, @intFromEnum(level)) << 3) | mask;
    const rem = bchRemainder(data, 0x537, 11, 15);
    return @intCast(((data << 10) | rem) ^ 0x5412);
}

fn versionBits(version: u8) u18 {
    const data: u32 = version;
    const rem = bchRemainder(data, 0x1F25, 13, 18);
    return @intCast((data << 12) | rem);
}

// ── Encoding ───────────────────────────────────────────────────────────────

fn chooseVersion(len: usize, level: EcLevel) Error!u8 {
    for (1..41) |v| {
        if (byteCapacity(@intCast(v), level) >= len) return @intCast(v);
    }
    return Error.DataTooLong;
}

const BitWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn put(self: *BitWriter, value: u32, count: u5) void {
        var i: u5 = count;
        while (i > 0) {
            i -= 1;
            if ((value >> i) & 1 != 0) {
                self.buf[self.pos / 8] |= @as(u8, 0x80) >> @intCast(self.pos % 8);
            }
            self.pos += 1;
        }
    }
};

/// Encode `data` in byte mode at the smallest version that fits.
pub fn encodeBytes(allocator: std.mem.Allocator, data: []const u8, level: EcLevel) Error!Code {
    const version = try chooseVersion(data.len, level);
    const size: u16 = 17 + 4 * @as(u16, version);
    const b = blockInfo(version, level);
    const n_data = dataCodewords(version, level);
    const n_total = total_codewords[version - 1];

    // 1. Data codewords: mode, count, payload, terminator, byte pad, fill.
    const data_cw = try allocator.alloc(u8, n_data);
    defer allocator.free(data_cw);
    @memset(data_cw, 0);
    var w = BitWriter{ .buf = data_cw };
    w.put(0b0100, 4);
    w.put(@intCast(data.len), countBits(version));
    for (data) |byte| w.put(byte, 8);
    const capacity_bits = @as(usize, n_data) * 8;
    const terminator: u5 = @intCast(@min(4, capacity_bits - w.pos));
    w.put(0, terminator);
    if (w.pos % 8 != 0) w.put(0, @intCast(8 - w.pos % 8));
    var pad: u8 = 0xEC;
    while (w.pos < capacity_bits) : (pad ^= 0xEC ^ 0x11) w.put(pad, 8);

    // 2. Per-block EC, then interleave data and EC codewords.
    const final = try allocator.alloc(u8, n_total);
    defer allocator.free(final);
    const n_blocks: usize = @as(usize, b.g1_blocks) + b.g2_blocks;
    const ec_all = try allocator.alloc(u8, n_blocks * b.ec_per_block);
    defer allocator.free(ec_all);
    {
        var offset: usize = 0;
        for (0..n_blocks) |k| {
            const len: usize = if (k < b.g1_blocks) b.g1_data else b.g2_data;
            rsEncode(data_cw[offset .. offset + len], ec_all[k * b.ec_per_block ..][0..b.ec_per_block]);
            offset += len;
        }
    }
    {
        var out: usize = 0;
        const max_len: usize = if (b.g2_blocks != 0) b.g2_data else b.g1_data;
        for (0..max_len) |i| {
            var offset: usize = 0;
            for (0..n_blocks) |k| {
                const len: usize = if (k < b.g1_blocks) b.g1_data else b.g2_data;
                if (i < len) {
                    final[out] = data_cw[offset + i];
                    out += 1;
                }
                offset += len;
            }
        }
        for (0..b.ec_per_block) |i| {
            for (0..n_blocks) |k| {
                final[out] = ec_all[k * b.ec_per_block + i];
                out += 1;
            }
        }
        std.debug.assert(out == n_total);
    }

    // 3. Matrix with function patterns and reservations.
    const modules = try allocator.alloc(u8, @as(usize, size) * size);
    errdefer allocator.free(modules);
    @memset(modules, 0);
    const reserved = try allocator.alloc(u8, @as(usize, size) * size);
    defer allocator.free(reserved);
    @memset(reserved, 0);
    placeFunctionPatterns(modules, reserved, size, version);

    // 4. Zigzag placement of the codeword bits.
    placeData(modules, reserved, size, final);

    // 5. Try every mask; keep the lowest penalty.
    const trial = try allocator.alloc(u8, @as(usize, size) * size);
    defer allocator.free(trial);
    var best_mask: u3 = 0;
    var best_penalty: u32 = std.math.maxInt(u32);
    for (0..8) |m| {
        const mask: u3 = @intCast(m);
        @memcpy(trial, modules);
        applyMask(trial, reserved, size, mask);
        placeFormat(trial, size, level, mask);
        const p = penalty(trial, size);
        if (p < best_penalty) {
            best_penalty = p;
            best_mask = mask;
        }
    }
    applyMask(modules, reserved, size, best_mask);
    placeFormat(modules, size, level, best_mask);
    if (version >= 7) placeVersion(modules, size, version);

    return .{ .version = version, .size = size, .modules = modules, .allocator = allocator };
}

fn set(modules: []u8, size: u16, x: usize, y: usize, dark: bool) void {
    modules[y * size + x] = if (dark) 1 else 0;
}

fn placeFunctionPatterns(modules: []u8, reserved: []u8, size: u16, version: u8) void {
    const n: usize = size;
    // Finders with separators: an 8x8 reserved square at each of three corners.
    const corners = [_][2]usize{ .{ 0, 0 }, .{ n - 7, 0 }, .{ 0, n - 7 } };
    for (corners) |c| {
        var dy: isize = -1;
        while (dy <= 7) : (dy += 1) {
            var dx: isize = -1;
            while (dx <= 7) : (dx += 1) {
                const x = @as(isize, @intCast(c[0])) + dx;
                const y = @as(isize, @intCast(c[1])) + dy;
                if (x < 0 or y < 0 or x >= n or y >= n) continue;
                const ux: usize = @intCast(x);
                const uy: usize = @intCast(y);
                const in_ring = (dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6) and
                    (dx == 0 or dx == 6 or dy == 0 or dy == 6 or (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4));
                set(modules, size, ux, uy, in_ring);
                reserved[uy * n + ux] = 1;
            }
        }
    }
    // Timing patterns.
    for (8..n - 8) |i| {
        set(modules, size, i, 6, i % 2 == 0);
        set(modules, size, 6, i, i % 2 == 0);
        reserved[6 * n + i] = 1;
        reserved[i * n + 6] = 1;
    }
    // Alignment patterns, skipping the three that would overlap finders.
    const centres = alignmentCentres(version);
    if (centres.len != 0) {
        const last = centres[centres.len - 1];
        for (centres) |cy| {
            for (centres) |cx| {
                if ((cx == 6 and cy == 6) or (cx == 6 and cy == last) or (cx == last and cy == 6)) continue;
                var dy: isize = -2;
                while (dy <= 2) : (dy += 1) {
                    var dx: isize = -2;
                    while (dx <= 2) : (dx += 1) {
                        const x: usize = @intCast(@as(isize, cx) + dx);
                        const y: usize = @intCast(@as(isize, cy) + dy);
                        const dark = @max(@abs(dx), @abs(dy)) != 1;
                        set(modules, size, x, y, dark);
                        reserved[y * n + x] = 1;
                    }
                }
            }
        }
    }
    // Format areas (both copies) and the dark module.
    for (0..9) |i| {
        reserved[8 * n + i] = 1;
        reserved[i * n + 8] = 1;
    }
    for (0..8) |i| {
        reserved[8 * n + (n - 1 - i)] = 1;
        reserved[(n - 1 - i) * n + 8] = 1;
    }
    set(modules, size, 8, n - 8, true);
    // Version areas.
    if (version >= 7) {
        for (0..18) |i| {
            reserved[(n - 11 + i % 3) * n + i / 3] = 1;
            reserved[(i / 3) * n + (n - 11 + i % 3)] = 1;
        }
    }
}

fn placeData(modules: []u8, reserved: []const u8, size: u16, codewords: []const u8) void {
    const n: usize = size;
    const total_bits = codewords.len * 8;
    var bit: usize = 0;
    var upward = true;
    var x: isize = @as(isize, @intCast(n)) - 1;
    while (x > 0) : (x -= 2) {
        if (x == 6) x -= 1;
        for (0..n) |step| {
            const y: usize = if (upward) n - 1 - step else step;
            for (0..2) |dx| {
                const xx: usize = @intCast(x - @as(isize, @intCast(dx)));
                if (reserved[y * n + xx] != 0) continue;
                var dark = false;
                if (bit < total_bits) {
                    dark = (codewords[bit / 8] >> @intCast(7 - bit % 8)) & 1 != 0;
                    bit += 1;
                }
                set(modules, size, xx, y, dark);
            }
        }
        upward = !upward;
    }
}

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        7 => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
    };
}

fn applyMask(modules: []u8, reserved: []const u8, size: u16, mask: u3) void {
    const n: usize = size;
    for (0..n) |y| {
        for (0..n) |x| {
            if (reserved[y * n + x] != 0) continue;
            if (maskBit(mask, x, y)) modules[y * n + x] ^= 1;
        }
    }
}

fn placeFormat(modules: []u8, size: u16, level: EcLevel, mask: u3) void {
    const n: usize = size;
    const bits: u15 = formatBits(level, mask);
    for (0..15) |i| {
        const dark = (bits >> @intCast(14 - i)) & 1 != 0;
        // First copy, around the top-left finder (bit 14 first).
        const first: [2]usize = if (i < 6) .{ i, 8 } else if (i == 6) .{ 7, 8 } else if (i == 7) .{ 8, 8 } else if (i == 8) .{ 8, 7 } else .{ 8, 14 - i };
        set(modules, size, first[0], first[1], dark);
        // Second copy: bits 14..8 down column 8 at the bottom, 7..0 along row 8 at the right.
        const second: [2]usize = if (i < 7) .{ 8, n - 1 - i } else .{ n - 15 + i, 8 };
        set(modules, size, second[0], second[1], dark);
    }
}

fn placeVersion(modules: []u8, size: u16, version: u8) void {
    const n: usize = size;
    const bits: u18 = versionBits(version);
    for (0..18) |i| {
        const dark = (bits >> @intCast(i)) & 1 != 0;
        set(modules, size, i / 3, n - 11 + i % 3, dark);
        set(modules, size, n - 11 + i % 3, i / 3, dark);
    }
}

/// The four penalty rules of ISO 18004 section 7.8.3.
fn penalty(modules: []const u8, size: u16) u32 {
    const n: usize = size;
    var score: u32 = 0;
    // Rule 1: runs of five or more same-colour modules in a row or column.
    for (0..n) |a| {
        var run_row: u32 = 1;
        var run_col: u32 = 1;
        for (1..n) |b| {
            if (modules[a * n + b] == modules[a * n + b - 1]) {
                run_row += 1;
                if (run_row == 5) score += 3 else if (run_row > 5) score += 1;
            } else run_row = 1;
            if (modules[b * n + a] == modules[(b - 1) * n + a]) {
                run_col += 1;
                if (run_col == 5) score += 3 else if (run_col > 5) score += 1;
            } else run_col = 1;
        }
    }
    // Rule 2: 2x2 blocks of one colour.
    for (0..n - 1) |y| {
        for (0..n - 1) |x| {
            const v = modules[y * n + x];
            if (v == modules[y * n + x + 1] and v == modules[(y + 1) * n + x] and v == modules[(y + 1) * n + x + 1]) score += 3;
        }
    }
    // Rule 3: finder-like 1011101 with four light modules on one side.
    const p1 = [_]u8{ 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0 };
    const p2 = [_]u8{ 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1 };
    for (0..n) |a| {
        var b: usize = 0;
        while (b + 11 <= n) : (b += 1) {
            var row1 = true;
            var row2 = true;
            var col1 = true;
            var col2 = true;
            for (0..11) |k| {
                const r = modules[a * n + b + k];
                const c = modules[(b + k) * n + a];
                if (r != p1[k]) row1 = false;
                if (r != p2[k]) row2 = false;
                if (c != p1[k]) col1 = false;
                if (c != p2[k]) col2 = false;
            }
            if (row1 or row2) score += 40;
            if (col1 or col2) score += 40;
        }
    }
    // Rule 4: deviation of the dark proportion from 50%, in steps of 5%.
    var dark: usize = 0;
    for (modules) |m| dark += m;
    const percent = dark * 100 / (n * n);
    const lower = percent / 5 * 5;
    const upper = lower + 5;
    const dl = if (lower > 50) lower - 50 else 50 - lower;
    const du = if (upper > 50) upper - 50 else 50 - upper;
    score += @intCast(@min(dl, du) / 5 * 10);
    return score;
}

/// Portable bitmap (P1) of the code with the four-module quiet zone the
/// specification requires; a test and debugging aid, never the product.
pub fn toPbm(allocator: std.mem.Allocator, code: Code) std.mem.Allocator.Error![]u8 {
    const quiet = 4;
    const w: usize = @as(usize, code.size) + 2 * quiet;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var header: [32]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "P1\n{d} {d}\n", .{ w, w }) catch unreachable;
    try out.appendSlice(allocator, h);
    for (0..w) |y| {
        for (0..w) |x| {
            const inside = x >= quiet and y >= quiet and x < w - quiet and y < w - quiet;
            const dark = inside and code.get(x - quiet, y - quiet);
            try out.append(allocator, if (dark) '1' else '0');
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "EC table: every version's blocks sum to its codeword total" {
    // The block table (160 rows) is transcribed by hand; the codeword totals
    // per version are an independent list. A typo in any block count or data
    // count breaks the equality for that row.
    for (1..41) |v| {
        for ([_]EcLevel{ .L, .M, .Q, .H }) |level| {
            const b = blockInfo(@intCast(v), level);
            const sum: u32 = @as(u32, b.g1_blocks) * (@as(u32, b.g1_data) + b.ec_per_block) +
                @as(u32, b.g2_blocks) * (@as(u32, b.g2_data) + b.ec_per_block);
            testing.expectEqual(total_codewords[v - 1], sum) catch |e| {
                std.debug.print("version {d} level {s}: blocks sum to {d}, want {d}\n", .{ v, @tagName(level), sum, total_codewords[v - 1] });
                return e;
            };
            if (b.g2_blocks != 0) try testing.expectEqual(@as(u16, b.g1_data) + 1, b.g2_data);
        }
    }
}

test "byte-mode capacities match the specification's corner cases" {
    try testing.expectEqual(@as(usize, 17), byteCapacity(1, .L));
    try testing.expectEqual(@as(usize, 14), byteCapacity(1, .M));
    try testing.expectEqual(@as(usize, 11), byteCapacity(1, .Q));
    try testing.expectEqual(@as(usize, 7), byteCapacity(1, .H));
    try testing.expectEqual(@as(usize, 2953), byteCapacity(40, .L));
    try testing.expectEqual(@as(usize, 2331), byteCapacity(40, .M));
    try testing.expectEqual(@as(usize, 1663), byteCapacity(40, .Q));
    try testing.expectEqual(@as(usize, 1273), byteCapacity(40, .H));
}

test "alignment centres: the last one always sits seven modules from the edge" {
    for (2..41) |v| {
        const centres = alignmentCentres(@intCast(v));
        try testing.expectEqual(@as(u8, 6), centres[0]);
        try testing.expectEqual(@as(u8, @intCast(17 + 4 * v - 7)), centres[centres.len - 1]);
    }
    try testing.expectEqual(@as(usize, 0), alignmentCentres(1).len);
}

test "Reed-Solomon generator polynomial for 7 codewords is the standard one" {
    // Coefficients in integer form, highest degree first.
    var gen: [rs_max_ec + 1]u8 = undefined;
    const g = rsGenerator(&gen, 7);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 127, 122, 154, 164, 11, 68, 117 }, g);
}

// No hand-remembered Reed-Solomon block vector lives here: one was tried and
// was wrong. The EC output is judged end to end instead: zbar decodes the
// rendered code at every version (tests/cli/test_cli), and a decoder cannot
// succeed against a block whose EC codewords are all wrong.

test "format information is BCH-protected and masked per the specification" {
    try testing.expectEqual(@as(u15, 0x5412), formatBits(.M, 0));
    try testing.expectEqual(@as(u15, 0x77C4), formatBits(.L, 0));
}

test "version information for version 7 matches the specification" {
    try testing.expectEqual(@as(u18, 0x07C94), versionBits(7));
}

test "the smallest version that fits is chosen" {
    const a = testing.allocator;
    var c1 = try encodeBytes(a, "x" ** 14, .M);
    defer c1.deinit();
    try testing.expectEqual(@as(u8, 1), c1.version);
    try testing.expectEqual(@as(u16, 21), c1.size);
    var c2 = try encodeBytes(a, "x" ** 15, .M);
    defer c2.deinit();
    try testing.expectEqual(@as(u8, 2), c2.version);
    try testing.expectEqual(@as(u16, 25), c2.size);
    var c40 = try encodeBytes(a, "x" ** 2331, .M);
    defer c40.deinit();
    try testing.expectEqual(@as(u8, 40), c40.version);
    try testing.expectError(error.DataTooLong, encodeBytes(a, "x" ** 2332, .M));
}

test "function patterns: finders, timing and the dark module are in place" {
    const a = testing.allocator;
    var c = try encodeBytes(a, "sigil", .M);
    defer c.deinit();
    const n = c.size;
    // Finder outer rings are dark at the three corners; separators are light.
    for ([_][2]usize{ .{ 0, 0 }, .{ n - 7, 0 }, .{ 0, n - 7 } }) |origin| {
        for (0..7) |i| {
            try testing.expect(c.get(origin[0] + i, origin[1]));
            try testing.expect(c.get(origin[0] + i, origin[1] + 6));
            try testing.expect(c.get(origin[0], origin[1] + i));
            try testing.expect(c.get(origin[0] + 6, origin[1] + i));
        }
        try testing.expect(c.get(origin[0] + 3, origin[1] + 3));
        try testing.expect(!c.get(origin[0] + 1, origin[1] + 1));
    }
    try testing.expect(!c.get(7, 7));
    // Timing patterns alternate starting dark at (8, 6) / (6, 8).
    for (8..n - 8) |i| {
        try testing.expectEqual(i % 2 == 0, c.get(i, 6));
        try testing.expectEqual(i % 2 == 0, c.get(6, i));
    }
    // The always-dark module.
    try testing.expect(c.get(8, n - 8));
}

test "masking is an involution on the data region" {
    var m: [21 * 21]u8 = @splat(0);
    var reserved: [21 * 21]u8 = @splat(0);
    m[21 * 10 + 10] = 1;
    for (0..8) |mask| {
        const before = m;
        applyMask(&m, &reserved, 21, @intCast(mask));
        applyMask(&m, &reserved, 21, @intCast(mask));
        try testing.expectEqualSlices(u8, &before, &m);
    }
}

test "PBM rendering is a valid P1 bitmap with a four-module quiet zone" {
    const a = testing.allocator;
    var c = try encodeBytes(a, "sigil", .L);
    defer c.deinit();
    const pbm = try toPbm(a, c);
    defer a.free(pbm);
    try testing.expect(std.mem.startsWith(u8, pbm, "P1\n29 29\n"));
    var lines = std.mem.splitScalar(u8, pbm, '\n');
    _ = lines.next();
    _ = lines.next();
    var rows: usize = 0;
    while (lines.next()) |row| : (rows += 1) {
        if (row.len == 0) break;
        try testing.expectEqual(@as(usize, 29), row.len);
        if (rows < 4 or rows >= 25) try testing.expect(std.mem.indexOfScalar(u8, row, '1') == null);
    }
    try testing.expectEqual(@as(usize, 29), rows);
}
