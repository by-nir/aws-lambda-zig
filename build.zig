const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptionsQueryOnly(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const lib = b.addModule("aws-lambda", .{
        .root_source_file = .{ .path = "src/root.zig" },
    });

    //
    // Unit Tests
    //

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = b.resolveTargetQuery(target),
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    //
    // Demos
    //

    // zig fmt: off
    const demos = .{
        "echo", "debug", "fail", "oversize", "stream", "stream_throw",
    };
    // zig fmt: on

    const demo_target = resolveDemoTarget(b, target);
    inline for (demos) |name| {
        addDemo(b, demo_target, optimize, name, lib);
    }
}

fn resolveDemoTarget(b: *std.Build, query: std.Target.Query) std.Build.ResolvedTarget {
    var q = query;
    q.os_tag = .linux;
    if (q.cpu_arch == null) q.cpu_arch = .aarch64;
    switch (q.cpu_arch.?) {
        // https://github.com/aws/aws-graviton-getting-started/tree/eb2d645a915d44d2693f161881e4778318ee6c3c?tab=readme-ov-file#building-for-graviton2-graviton3-and-graviton3e
        .aarch64 => q.cpu_model = .{ .explicit = &std.Target.aarch64.cpu.neoverse_n1 },
        .x86_64 => q.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.avx2)),
        else => |cpu| std.log.err("Unsupported architecture: {s}", .{@tagName(cpu)}),
    }
    return b.resolveTargetQuery(q);
}

fn addDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime name: []const u8,
    lib: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = "bootstrap",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "demo/" ++ name ++ ".zig" },
    });
    exe.root_module.addImport("aws-lambda", lib);

    const install_exe = b.addInstallArtifact(exe, .{});

    const build_exe_step = b.step("demo:" ++ name, "Build " ++ name ++ " tests");
    build_exe_step.dependOn(&install_exe.step);
}
