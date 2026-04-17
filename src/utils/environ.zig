const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn load(env: *std.process.Environ.Map, gpa: Allocator) !void {
    const process_environ: std.process.Environ = if (@import("builtin").link_libc)
        .{ .block = std.c.environ }
    else
        .empty;

    env.* = try process_environ.createMap(gpa);
}
