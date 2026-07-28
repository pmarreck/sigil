//! C ABI (FFI) surface for printable_binary.
//!
//! This file is the root of the static FFI library (libprintable_binary.a) and
//! is the ONLY place the `export fn pb_*` C symbols are defined. The pure Zig
//! API lives in printable_binary.zig, which downstream Zig packages import
//! directly. Keeping the C exports out of the importable module is what lets
//! multiple static (musl) consumers link without colliding on
//! `duplicate symbol: pb_*` (see test/test_module_no_ffi_symbols, and the difz
//! static-link failure that motivated this split).
const std = @import("std");
const pb = @import("printable_binary.zig");

// Use page allocator for FFI - simple and doesn't require libc
const ffi_allocator = std.heap.page_allocator;

/// C ABI export for double-encoding detection
export fn pb_detect_double_encode(input: ?[*]const u8, input_len: usize, threshold: f32) callconv(.c) pb.DoubleEncodeInfo {
	if (input == null and input_len > 0) {
		return pb.DoubleEncodeInfo{ .detected = 0, .confidence = 0.0 };
	}
	const slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};
	return pb.detectDoubleEncode(slice, threshold);
}

/// C ABI export for hexlike encoding. Caller must call pb_free() on result.data.
export fn pb_hexlike_encode(input: ?[*]const u8, input_len: usize, spaces: c_int) callconv(.c) pb.FFIResult {
	if (input == null and input_len > 0) {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	}
	const input_slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};
	const result = pb.hexlikeEncode(ffi_allocator, input_slice, .{ .spaces = spaces != 0 }) catch {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	};
	return pb.FFIResult{ .data = result.ptr, .len = result.len, .error_code = 0 };
}

/// C ABI export for hexlike decoding. Caller must call pb_free() on result.data.
export fn pb_hexlike_decode(input: ?[*]const u8, input_len: usize, spaces: c_int) callconv(.c) pb.FFIResult {
	if (input == null and input_len > 0) {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	}
	const input_slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};
	const result = pb.hexlikeDecode(ffi_allocator, input_slice, .{ .spaces = spaces != 0 }) catch {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	};
	return pb.FFIResult{ .data = result.data.ptr, .len = result.data.len, .error_code = 0 };
}

/// C ABI export for hexlike detection. Returns 1 if input appears hexlike, else 0.
export fn pb_detect_hexlike(input: ?[*]const u8, input_len: usize) callconv(.c) c_int {
	if (input == null and input_len > 0) return 0;
	const input_slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};
	return if (pb.detectHexlike(input_slice)) 1 else 0;
}

/// C ABI export for validation function
export fn pb_validate(input: ?[*]const u8, input_len: usize, ws_flags: c_uint) callconv(.c) pb.ValidationResult {
	if (input == null and input_len > 0) {
		return pb.ValidationResult{ .is_valid = 0, .error_position = 0, .error_codepoint = 0 };
	}
	const slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};
	return pb.validate(slice, ws_flags);
}

/// C ABI export for range resolution function
export fn pb_apply_range(input_len: usize, has_start: c_int, start: i64, has_end: c_int, end: i64) callconv(.c) pb.RangeResult {
	const opt_start: ?i64 = if (has_start != 0) start else null;
	const opt_end: ?i64 = if (has_end != 0) end else null;
	return pb.applyRange(input_len, opt_start, opt_end);
}

/// Free memory allocated by pb_encode, pb_decode, or pb_format
export fn pb_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
	if (ptr) |p| {
		ffi_allocator.free(p[0..len]);
	}
}

/// C ABI export for encode function
/// Caller must call pb_free() on result.data when done
export fn pb_encode(
	input: ?[*]const u8,
	input_len: usize,
	flags: c_uint,
	preserve_chars: ?[*]const u8,
	preserve_chars_len: usize,
) callconv(.c) pb.FFIResult {
	if (input == null and input_len > 0) {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	}
	const input_slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};
	const preserve_slice = if (preserve_chars != null and preserve_chars_len > 0)
		preserve_chars.?[0..preserve_chars_len]
	else
		&[_]u8{};

	const options = pb.EncodeOptions{
		.spaces = (flags & @intFromEnum(pb.EncodeFlags.preserve_spaces)) != 0,
		.tabs = (flags & @intFromEnum(pb.EncodeFlags.preserve_tabs)) != 0,
		.crlf = (flags & @intFromEnum(pb.EncodeFlags.preserve_crlf)) != 0,
		.preserve_chars = preserve_slice,
	};

	const result = pb.encode(ffi_allocator, input_slice, options) catch {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	};

	return pb.FFIResult{
		.data = result.ptr,
		.len = result.len,
		.error_code = 0,
	};
}

/// C ABI export for decode function
/// Caller must call pb_free() on result.data when done
export fn pb_decode(
	input: ?[*]const u8,
	input_len: usize,
	flags: c_uint,
) callconv(.c) pb.FFIResult {
	if (input == null and input_len > 0) {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	}
	const input_slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};

	const options = pb.DecodeOptions{
		.spaces = (flags & @intFromEnum(pb.DecodeFlags.spaces_mode)) != 0,
		.strip_whitespace = (flags & @intFromEnum(pb.DecodeFlags.strip_whitespace)) != 0,
	};

	const result = pb.decode(ffi_allocator, input_slice, options) catch {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	};

	return pb.FFIResult{
		.data = result.ptr,
		.len = result.len,
		.error_code = 0,
	};
}

/// C ABI export for format function
/// Caller must call pb_free() on result.data when done
export fn pb_format(
	input: ?[*]const u8,
	input_len: usize,
	group_size: usize,
	groups_per_line: usize,
	use_tabs: c_int,
) callconv(.c) pb.FFIResult {
	if (input == null and input_len > 0) {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	}
	const input_slice = if (input_len > 0) input.?[0..input_len] else &[_]u8{};

	const options = pb.FormatOptions{
		.group_size = if (group_size > 0) group_size else 8,
		.groups_per_line = if (groups_per_line > 0) groups_per_line else 10,
		.use_tabs = use_tabs != 0,
	};

	const result = pb.format(ffi_allocator, input_slice, options) catch {
		return pb.FFIResult{ .data = null, .len = 0, .error_code = 1 };
	};

	return pb.FFIResult{
		.data = result.ptr,
		.len = result.len,
		.error_code = 0,
	};
}

/// Get the mapping for a byte value (returns pointer to static data, do not free)
export fn pb_get_mapping(byte: u8) callconv(.c) [*]const u8 {
	return pb.character_map[byte].ptr;
}

/// Get the length of a mapping for a byte value
export fn pb_get_mapping_len(byte: u8) callconv(.c) usize {
	return pb.character_map[byte].len;
}

// =============================================================================
// Unit Tests (C ABI surface)
// =============================================================================

test "FFI: null input pointer with nonzero len returns error instead of crashing" {
	// A defensive C caller may pass NULL together with a stale, nonzero length.
	// Every C ABI entry point must report an error rather than dereference NULL.
	const enc = pb_encode(null, 100, 0, null, 0);
	try std.testing.expectEqual(@as(?[*]u8, null), enc.data);
	try std.testing.expect(enc.error_code != 0);

	const dec = pb_decode(null, 100, 0);
	try std.testing.expectEqual(@as(?[*]u8, null), dec.data);
	try std.testing.expect(dec.error_code != 0);

	const fmt = pb_format(null, 100, 8, 10, 0);
	try std.testing.expectEqual(@as(?[*]u8, null), fmt.data);
	try std.testing.expect(fmt.error_code != 0);

	const val = pb_validate(null, 100, 0);
	try std.testing.expect(val.is_valid == 0);
	try std.testing.expect(val.error_position == 0);

	const dbl = pb_detect_double_encode(null, 100, 0.5);
	try std.testing.expect(dbl.detected == 0);
	try std.testing.expect(dbl.confidence == 0.0);
}

test "FFI: pb_hexlike_encode/decode roundtrip + detect + null safety" {
	const input = "Hi\xff!";
	const enc = pb_hexlike_encode(input.ptr, input.len, 0);
	try std.testing.expect(enc.error_code == 0);
	defer pb_free(enc.data, enc.len);
	try std.testing.expect(pb_detect_hexlike(enc.data, enc.len) == 1);
	const dec = pb_hexlike_decode(enc.data, enc.len, 0);
	try std.testing.expect(dec.error_code == 0);
	defer pb_free(dec.data, dec.len);
	try std.testing.expectEqualStrings(input, dec.data.?[0..dec.len]);
	// null safety
	const bad = pb_hexlike_encode(null, 100, 0);
	try std.testing.expect(bad.error_code != 0);
	try std.testing.expect(pb_detect_hexlike(null, 100) == 0);
}

/// FFI: CRC-32/ISO-HDLC of `len` bytes at `input`. Null ptr (or len 0) yields
/// the CRC of empty input (0). Delegates to the pure core `pb.crc32`.
export fn pb_crc32(input: ?[*]const u8, len: usize) callconv(.c) u32 {
	if (input == null or len == 0) return pb.crc32("");
	return pb.crc32(input.?[0..len]);
}

test "FFI: pb_crc32 matches vectors + null safety" {
	const s = "123456789";
	try std.testing.expectEqual(@as(u32, 0xCBF43926), pb_crc32(s.ptr, s.len));
	try std.testing.expectEqual(@as(u32, 0), pb_crc32(null, 100));
}
