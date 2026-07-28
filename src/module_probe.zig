//! A test fixture, never a deliverable. It exists to give `nm` something to read.
//!
//! `b.addModule("sigil")` produces no binary at all, so the custody control was
//! blind to the *sanctioned* consumer path: the canonical brief's sibling-Zig
//! exception explicitly permits Mecha Validate and Mecha Rotshield to import
//! the module directly rather than going through the C ABI. A review confirmed
//! the gap by adding `pub const` re-exports to lib.zig — the archive stayed
//! byte-identical (Zig does not codegen unreferenced declarations) while a Zig
//! consumer minted a valid signature.
//!
//! Forcing a reference to every public declaration compiles the module's whole
//! reachable surface, so the same cryptographic oracle used on libsigil.a
//! applies here: if signing is reachable from `@import("sigil")`, then
//! Edwards25519.mul and scalar.reduce64 appear in this artifact's symbol table.
//!
//! Installed to zig-out/test-fixtures/, deliberately NOT zig-out/lib/, so it can
//! never be mistaken for something to ship.
//!
//! NB: `std.testing.refAllDecls` is unusable for this — it is non-recursive, and
//! its body begins `if (!builtin.is_test) return;`, so in a library build it
//! compiles to nothing at all and would have made this probe silently vacuous.

const std = @import("std");
const sigil = @import("sigil");

/// Sum the addresses of every function reachable from `T`, recursing into
/// declarations that are themselves types — which is exactly what a re-exported
/// module looks like: `pub const sign = @import("sign.zig")`.
///
/// Taking a function's ADDRESS is what forces the backend to emit its body.
/// Merely naming it, as `_ = &@field(...)` in a comptime block does, satisfies
/// the semantic analyzer and is then eliminated: the first version of this
/// probe did exactly that and produced an archive with two symbols in it.
fn sumFnAddrs(comptime T: type, comptime depth: u8) usize {
    // Runtime, not comptime: a function's address is not known until link time,
    // and accumulating it is the whole point — a comptime sum would fold away.
    var acc: usize = 0;
    if (depth == 0) return 0;
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return 0,
    }
    inline for (comptime std.meta.declarations(T)) |decl| {
        const F = @TypeOf(@field(T, decl.name));
        if (F == type) {
            acc +%= sumFnAddrs(@field(T, decl.name), depth - 1);
        } else if (@typeInfo(F) == .@"fn") {
            // A generic function has no address until instantiated; there are
            // none in this module's surface, and skipping is the honest thing
            // rather than failing to compile.
            if (!@typeInfo(F).@"fn".is_generic) {
                acc +%= @intFromPtr(&@field(T, decl.name));
            }
        }
    }
    return acc;
}

/// The anchor. Without an `export`, a static library with no external
/// references is dead code in its entirety and the archive comes out empty —
/// which would make this whole control vacuous rather than merely weak.
///
/// Depth 4 comfortably covers a module re-exporting a module re-exporting a
/// namespace; the real surface is a couple of levels deep.
export fn sigil_module_probe_anchor() usize {
    return sumFnAddrs(sigil, 4);
}
