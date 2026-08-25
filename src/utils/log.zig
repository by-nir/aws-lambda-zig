const std = @import("std");
const builtin = @import("builtin");

/// The runtime’s logging scope.
///
/// The test build drops these messages. Tests drive the runtime’s error paths
/// on purpose, and Zig’s test runner counts a logged error as a failure.
pub const runtime = if (builtin.is_test) quiet else std.log.scoped(.Runtime);

const quiet = struct {
    pub fn err(comptime _: []const u8, _: anytype) void {}
    pub fn warn(comptime _: []const u8, _: anytype) void {}
    pub fn info(comptime _: []const u8, _: anytype) void {}
    pub fn debug(comptime _: []const u8, _: anytype) void {}
};

/// The handler’s logging scope.
///
/// In release mode, only the _error_ level is preserved; other levels are
/// removed at compile time.
/// This behavior may be overridden at build time.
pub const handler = std.log.scoped(.Handler);
