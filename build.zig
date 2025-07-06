const std = @import("std");
const bld_target = @import("build/target.zig");
pub const Arch = bld_target.Arch;
pub const archOption = bld_target.archOption;
pub const resolveTargetQuery = bld_target.resolveTargetQuery;

pub fn build(b: *std.Build) void {
    const zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    addAllDemos(b, zon_mod);
    addUnitTests(b, zon_mod);
}

fn addUnitTests(b: *std.Build, zon_mod: *std.Build.Module) void {
    const target = b.standardTargetOptions(.{});

    const lib = b.addModule("lambda", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build-meta", .module = zon_mod },
        },
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = lib,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

fn addAllDemos(b: *std.Build, zon_mod: *std.Build.Module) void {
    const target = resolveTargetQuery(b, archOption(b));
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });
    const lib = b.addModule("lambda", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "build-meta", .module = zon_mod },
        },
    });

    addDemo(b, target, optimize, "hello", "demo/hello.zig", lib);
    addDemo(b, target, optimize, "echo", "demo/echo.zig", lib);
    addDemo(b, target, optimize, "debug", "demo/debug.zig", lib);
    addDemo(b, target, optimize, "fail", "demo/fail.zig", lib);
    addDemo(b, target, optimize, "oversize", "demo/oversize.zig", lib);
    addDemo(b, target, optimize, "terminate", "demo/terminate.zig", lib);
    addDemo(b, target, optimize, "stream", "demo/stream.zig", lib);
    addDemo(b, target, optimize, "url", "demo/url_buffer.zig", lib);
    addDemo(b, target, optimize, "url_stream", "demo/url_stream.zig", lib);
}

fn addDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime name: []const u8,
    path: []const u8,
    lib: *std.Build.Module,
) void {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(path),
        // .strip = true,
        // .link_libc = true,
        .imports = &.{
            .{ .name = "aws-lambda", .module = lib },
        },
    });

    const exe = b.addExecutable(.{
        .name = "bootstrap",
        .root_module = mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{});

    const build_exe_step = b.step("demo:" ++ name, "Build " ++ name ++ " tests");
    build_exe_step.dependOn(&install_exe.step);
}
