const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn load(env: *std.process.EnvMap, allocator: Allocator) !void {
    env.* = std.process.EnvMap.init(allocator);
    if (@import("builtin").link_libc) {
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) try parseAndPutVar(env, line);
    } else {
        for (std.os.environ) |line| try parseAndPutVar(env, line);
    }
}

/// Based on std.process.getEnvMap
fn parseAndPutVar(map: *std.process.EnvMap, line: [*]u8) !void {
    var line_i: usize = 0;
    while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
    const key = line[0..line_i];

    var end_i: usize = line_i;
    while (line[end_i] != 0) : (end_i += 1) {}
    const value = line[line_i + 1 .. end_i];

    try map.putMove(key, value);
}
