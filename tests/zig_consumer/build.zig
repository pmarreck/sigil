//! A downstream Zig consumer of sigil, built by tests/integration/zig_consumer.sh.
//! It does exactly what an embedding product does: `artifact("sigil")` must
//! resolve to the static verifier library on every target, and the C
//! conformance program must link against it through the C ABI.
const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});
	const dep = b.dependency("sigil", .{ .target = target, .optimize = optimize });
	const verifier = dep.artifact("sigil");
	if (verifier.kind != .lib or verifier.linkage != .static)
		@panic("artifact(\"sigil\") is not the static verifier library");

	// Resolving the artifact is the whole check for a cross target.
	b.step("resolve", "Resolve and compile the verifier artifact").dependOn(&verifier.step);

	const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
	mod.addCSourceFile(.{ .file = dep.path("tests/conformance/verify_conformance.c"), .flags = &.{"-std=c11"} });
	mod.addIncludePath(dep.path("include"));
	mod.linkLibrary(verifier);
	const exe = b.addExecutable(.{ .name = "verify_conformance", .root_module = mod });
	b.installArtifact(exe);
}
