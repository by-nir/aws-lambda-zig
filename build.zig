const std = @import("std");
const bld_target = @import("build/target.zig");
pub const Arch = bld_target.Arch;
pub const archOption = bld_target.archOption;
pub const resolveTargetQuery = bld_target.resolveTargetQuery;

pub fn build(b: *std.Build) void {
    const lib = b.addModule("lambda", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    //
    // Unit Tests
    //
    {
        const target = b.standardTargetOptionsQueryOnly(.{});

        const lib_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.resolveTargetQuery(target),
            .optimize = optimize,
        });
        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
    }

    //
    // Demos
    //
    {
        const target = resolveTargetQuery(b, archOption(b));
        addDemo(b, target, optimize, "hello", "demo/hello.zig", lib);
        addDemo(b, target, optimize, "echo", "demo/echo.zig", lib);
        addDemo(b, target, optimize, "debug", "demo/debug.zig", lib);
        addDemo(b, target, optimize, "fail", "demo/fail.zig", lib);
        addDemo(b, target, optimize, "oversize", "demo/oversize.zig", lib);
        addDemo(b, target, optimize, "stream", "demo/stream.zig", lib);
        addDemo(b, target, optimize, "stream_throw", "demo/stream_throw.zig", lib);
    }
}

fn addDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime name: []const u8,
    path: []const u8,
    lib: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = "bootstrap",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(path),
    });
    exe.root_module.addImport("aws-lambda", lib);

    const install_exe = b.addInstallArtifact(exe, .{});

    const build_exe_step = b.step("demo:" ++ name, "Build " ++ name ++ " tests");
    build_exe_step.dependOn(&install_exe.step);
}
