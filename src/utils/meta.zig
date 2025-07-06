const build_meta: struct {
    name: @TypeOf(.enum_literal),
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {},
    paths: []const []const u8,
} = @import("build-meta");

pub const package_version = build_meta.version;
