const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// -- Core module (pure Zig, no I/O) for downstream Zig consumers --
	_ = b.addModule("sigil", .{
		.root_source_file = b.path("src/lib.zig"),
		.target = target,
		.optimize = optimize,
	});

	// -- Static library exposing the C ABI (the real public API) --
	const lib = b.addLibrary(.{
		.name = "sigil",
		.linkage = .static,
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib.zig"),
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});
	b.installArtifact(lib);

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
	b.installArtifact(cli);

	const run_cmd = b.addRunArtifact(cli);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| run_cmd.addArgs(args);
	b.step("run", "Run the CLI").dependOn(&run_cmd.step);

	const run_tests = b.addRunArtifact(b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib.zig"),
			.target = target,
			.optimize = optimize,
		}),
	}));
	b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
