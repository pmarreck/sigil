const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// printable_binary's importable Zig module carries NO `pb_*` C exports (its
	// C ABI lives in a separate FFI root), so pulling it in here cannot collide
	// with a downstream that also links libprintable_binary.a. Importing the
	// sibling module directly is sanctioned because printable_binary already
	// dogfoods its own C FFI elsewhere; see the canonical brief.
	const pb_dep = b.dependency("printable_binary", .{
		.target = target,
		.optimize = optimize,
	});
	const pb_mod = pb_dep.module("printable_binary");

	// -- Core module (pure Zig, no I/O, NO C exports) for downstream Zig
	//    consumers. Deliberately does not link libc: an embedder must be able
	//    to take the verifier without taking a libc dependency. --
	const core_mod = b.addModule("sigil", .{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
	});
	core_mod.addImport("printable_binary", pb_mod);

	// -- Static library exposing the C ABI (the real public API). Its root is
	//    src/ffi.zig, which holds every `export fn sigil_*`, so the C ABI is
	//    emitted ONLY here and never in the importable module above. --
	const ffi_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	ffi_mod.addImport("printable_binary", pb_mod);

	const lib = b.addLibrary(.{
		.name = "sigil",
		.linkage = .static,
		.root_module = ffi_mod,
	});
	b.installArtifact(lib);

	// -- Signing library, kept SEPARATE from libsigil.a. The products link the
	//    verifier only, so a shipped binary does not contain the code to mint a
	//    license. tests/test_no_signing_symbols holds that to account with nm. --
	const sign_ffi_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi_sign.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	sign_ffi_mod.addImport("printable_binary", pb_mod);

	const sign_lib = b.addLibrary(.{
		.name = "sigil_sign",
		.linkage = .static,
		.root_module = sign_ffi_mod,
	});
	b.installArtifact(sign_lib);

	// -- C CLI: deliberately C, so it CANNOT @import the Zig core and must
	//    dogfood the FFI boundary that Validate and Rotshield will use. --
	const cli_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	cli_mod.addCSourceFile(.{
		.file = b.path("cli/main.c"),
		.flags = &.{ "-std=c11", "-Wall", "-Wextra" },
	});
	cli_mod.addIncludePath(b.path("include"));
	const cli = b.addExecutable(.{ .name = "sigil", .root_module = cli_mod });
	cli_mod.linkLibrary(lib);
	cli_mod.linkLibrary(sign_lib);
	b.installArtifact(cli);

	const run_cmd = b.addRunArtifact(cli);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| run_cmd.addArgs(args);
	b.step("run", "Run the CLI").dependOn(&run_cmd.step);

	// -- Unit tests --
	// Two roots on purpose. The core root does NOT link libc, so `zig build
	// test` fails loudly the moment the verifier picks up a libc dependency an
	// embedder would have to inherit.
	const core_test_mod = b.createModule(.{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
	});
	core_test_mod.addImport("printable_binary", pb_mod);
	const core_tests = b.addTest(.{ .root_module = core_test_mod });

	const ffi_test_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	ffi_test_mod.addImport("printable_binary", pb_mod);
	const ffi_tests = b.addTest(.{ .root_module = ffi_test_mod });

	// The signing core. Deliberately NOT reachable from src/lib.zig: keeping it
	// out of the importable module is what makes "a product cannot sign" a fact
	// about the linker rather than a rule someone has to remember.
	const sign_test_mod = b.createModule(.{
		.root_source_file = b.path("src/sign.zig"),
		.target = target,
		.optimize = optimize,
	});
	sign_test_mod.addImport("printable_binary", pb_mod);
	const sign_tests = b.addTest(.{ .root_module = sign_test_mod });

	const sign_ffi_test_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi_sign.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	sign_ffi_test_mod.addImport("printable_binary", pb_mod);
	const sign_ffi_tests = b.addTest(.{ .root_module = sign_ffi_test_mod });

	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&b.addRunArtifact(core_tests).step);
	test_step.dependOn(&b.addRunArtifact(ffi_tests).step);
	test_step.dependOn(&b.addRunArtifact(sign_tests).step);
	test_step.dependOn(&b.addRunArtifact(sign_ffi_tests).step);

	// Build the test binaries without running them. Nix builds need this: the
	// libc-linked test binary carries an FHS dynamic-linker path that does not
	// exist in the sandbox, so CI compiles here, patchelfs the results, then
	// runs `zig build test` against the now-runnable cached artifacts.
	const test_compile_step = b.step("test-compile", "Compile test binaries without running them");
	test_compile_step.dependOn(&core_tests.step);
	test_compile_step.dependOn(&ffi_tests.step);
	test_compile_step.dependOn(&sign_tests.step);
	test_compile_step.dependOn(&sign_ffi_tests.step);
}
