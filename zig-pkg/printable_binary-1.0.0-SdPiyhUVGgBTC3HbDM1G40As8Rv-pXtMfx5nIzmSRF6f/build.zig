const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    // =========================================================================
    // Core Library Module (for use by other Zig packages)
    // =========================================================================
    const lib_mod = b.addModule("printable_binary", .{
        .root_source_file = b.path("src/zig/printable_binary.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addAnonymousImport("character_map.txt", .{ .root_source_file = b.path("character_map.txt") });

    // =========================================================================
    // Static Library with C ABI (for FFI consumers like Cosmopolitan)
    // =========================================================================
    // Root is ffi.zig — the FFI-only file that holds every `export fn pb_*`.
    // It imports printable_binary.zig (relative), so the C ABI is emitted ONLY
    // here, never in the importable `printable_binary` module above. This is
    // what keeps static (musl) downstreams from colliding on duplicate pb_*
    // symbols. See src/zig/ffi.zig and test/test_module_no_ffi_symbols.
    const static_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/ffi.zig"),
        .target = target,
        .optimize = optimize,
        // Position-independent so the static lib links into PIE executables
        // (the default on modern Linux) — required by FFI consumers.
        .pic = true,
    });
    static_lib_mod.addAnonymousImport("character_map.txt", .{ .root_source_file = b.path("character_map.txt") });

    const static_lib = b.addLibrary(.{
        .name = "printable_binary",
        .linkage = .static,
        .root_module = static_lib_mod,
    });

    // Install the static library
    b.installArtifact(static_lib);

    // Also install the header for convenience
    b.installFile("src/printable_binary.h", "include/printable_binary.h");

    // =========================================================================
    // CLI Executable (Zig 0.15 style with root_module)
    // =========================================================================
    // CLI uses std.Io.File.{stderr,stdout}().writeStreamingAll for all
    // stderr/stdout I/O (Zig 0.16 portable API), so libc is not required on
    // any platform — including Windows.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = lib_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "printable-binary",
        .root_module = cli_mod,
    });

    b.installArtifact(exe);

    // =========================================================================
    // Run Command
    // =========================================================================
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // =========================================================================
    // Unit Tests (Zig 0.15 style with root_module)
    // =========================================================================
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/printable_binary.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("character_map.txt", .{ .root_source_file = b.path("character_map.txt") });

    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // FFI-surface tests (the C ABI wrappers now live in ffi.zig)
    const ffi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_test_mod.addAnonymousImport("character_map.txt", .{ .root_source_file = b.path("character_map.txt") });
    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(ffi_tests).step);

    // =========================================================================
    // Library-only step (for Makefile integration)
    // =========================================================================
    const lib_step = b.step("lib", "Build only the static library");
    lib_step.dependOn(&static_lib.step);

    // =========================================================================
    // Module-consumer static lib (FFI-symbol-leak regression test)
    // =========================================================================
    // Builds a downstream consumer that imports the `printable_binary` module
    // the way sibling Zig projects do. test/test_module_no_ffi_symbols asserts
    // the resulting archive carries NO `pb_*` C symbols — they must originate
    // only in the FFI-root static library (libprintable_binary.a). See
    // test/module_consumer.zig.
    const consumer_mod = b.createModule(.{
        .root_source_file = b.path("test/module_consumer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = lib_mod },
        },
    });
    const consumer_lib = b.addLibrary(.{
        .name = "module_consumer",
        .linkage = .static,
        .root_module = consumer_mod,
    });
    const consumer_lib_step = b.step("consumer-lib", "Build the module-consumer static lib (FFI-symbol-leak test fixture)");
    consumer_lib_step.dependOn(&b.addInstallArtifact(consumer_lib, .{}).step);
}
