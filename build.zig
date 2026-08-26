const std = @import("std");
const bld_target = @import("build/target.zig");
const bld_package = @import("build/package.zig");

pub const Arch = bld_target.Arch;
pub const archOption = bld_target.archOption;
pub const resolveTargetQuery = bld_target.resolveTargetQuery;

/// Packs the executable into a zip archive that AWS Lambda can deploy.
/// The archive holds a single file named `bootstrap`, marked executable.
///
/// Returns the archive’s path inside the build cache. Install it with
/// `b.addInstallFile(archive, "lambda.zip")`, or hand it to another step.
///
/// It builds a small packaging tool, so call it once per executable.
pub fn addPackageStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
) std.Build.LazyPath {
    const dep = b.dependencyFromBuildZig(@This(), .{});
    const tool = bld_package.addZipTool(b, dep.path("build/zip_cli.zig"));
    return bld_package.addZipArchive(b, tool, exe);
}

pub fn build(b: *std.Build) void {
    const zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    addDemos(b, zon_mod);
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

    const zip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/zip.zig"),
            .target = target,
        }),
    });
    const run_zip_tests = b.addRunArtifact(zip_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_zip_tests.step);
}

fn addDemos(b: *std.Build, zon_mod: *std.Build.Module) void {
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

    // One packaging tool serves every demo.
    const zip_tool = bld_package.addZipTool(b, b.path("build/zip_cli.zig"));

    addDemo(b, target, optimize, "hello", "demo/hello.zig", lib, zip_tool);
    addDemo(b, target, optimize, "echo", "demo/echo.zig", lib, zip_tool);
    addDemo(b, target, optimize, "debug", "demo/debug.zig", lib, zip_tool);
    addDemo(b, target, optimize, "fail", "demo/fail.zig", lib, zip_tool);
    addDemo(b, target, optimize, "oversize", "demo/oversize.zig", lib, zip_tool);
    addDemo(b, target, optimize, "terminate", "demo/terminate.zig", lib, zip_tool);
    addDemo(b, target, optimize, "stream", "demo/stream.zig", lib, zip_tool);
    addDemo(b, target, optimize, "url_buffer", "demo/url_buffer.zig", lib, zip_tool);
    addDemo(b, target, optimize, "url_stream", "demo/url_stream.zig", lib, zip_tool);
}

fn addDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime name: []const u8,
    path: []const u8,
    lib: *std.Build.Module,
    zip_tool: *std.Build.Step.Compile,
) void {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(path),
        // .strip = true,
        // .link_libc = true,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "aws-lambda", .module = lib },
        },
    });

    const exe = b.addExecutable(.{
        .name = "bootstrap",
        .root_module = mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{});

    // Deploying a demo needs the zip, so build it alongside the executable.
    const archive = bld_package.addZipArchive(b, zip_tool, exe);
    const install_archive = b.addInstallFile(archive, "lambda.zip");

    const build_exe_step = b.step("demo:" ++ name, "Build the " ++ name ++ " demo");
    build_exe_step.dependOn(&install_exe.step);
    build_exe_step.dependOn(&install_archive.step);
}
