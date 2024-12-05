const std = @import("std");
const Target = std.Target;

/// Lambda CPU architecture.
pub const Arch = enum {
    /// x86_64 with AVX2
    x86,
    /// aarch64 Graviton2
    arm,

    pub const default = .x86;

    pub fn targetQuery(self: Arch) Target.Query {
        return switch (self) {
            .x86 => x86_target,
            .arm => arm_target,
        };
    }
};

/// Creates a Lambda architecture configuration option `-Darch=(x86|arm)` and resolve an appropriate target query.
/// Defaults to _x86_.
pub fn archOption(b: *std.Build) std.Build.ResolvedTarget {
    const lambda_arch = b.option(Arch, "arch", "Lambda CPU architecture") orelse Arch.default;
    return b.resolveTargetQuery(lambda_arch.targetQuery());
}

const x86_target: Target.Query = blk: {
    break :blk .{
        .os_tag = .linux,
        .cpu_arch = .x86_64,
        .cpu_features_add = Target.x86.featureSet(&.{.avx2}),
    };
};

/// https://github.com/aws/aws-graviton-getting-started/tree/main?tab=readme-ov-file#building-for-graviton
const arm_target: Target.Query = blk: {
    break :blk .{
        .os_tag = .linux,
        .cpu_arch = .aarch64,
        .cpu_model = .{ .explicit = &Target.aarch64.cpu.neoverse_n1 },
        .cpu_features_add = Target.aarch64.featureSet(&.{.crypto}),
    };
};
