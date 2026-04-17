//! Returns the provided payload.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(_: lambda.Context, event: []const u8) ![]const u8 {
    return event;
}
