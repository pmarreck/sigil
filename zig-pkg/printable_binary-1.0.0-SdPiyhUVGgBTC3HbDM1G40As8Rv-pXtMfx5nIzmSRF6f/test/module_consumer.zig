//! Test fixture: a minimal downstream consumer of the importable
//! `printable_binary` Zig module (exactly how difz/blip/tiffz consume it).
//!
//! Purpose: prove the importable module emits NO C `pb_*` symbols. When a
//! consumer is statically linked (musl) alongside another copy of
//! printable_binary (e.g. blip's vendored instance), duplicate `export fn pb_*`
//! symbols make ld.lld abort. The C ABI must live ONLY in the FFI-root static
//! library, never in the importable module. test/test_module_no_ffi_symbols
//! nm-checks the static lib built from this root.
const pb = @import("printable_binary");

/// Reference a pure Zig API symbol so the module is genuinely pulled into the
/// compilation (not dead-code-eliminated). This export deliberately does NOT
/// start with `pb_` — the test asserts no `pb_*` symbols leak in from the module.
export fn module_consumer_touch() callconv(.c) usize {
	return pb.character_map.len;
}
