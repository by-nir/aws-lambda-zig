//! Returns an output larger than the Lambda limit.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

// The maximum Lambda payload size is 6 MB.
const output: [8 * 1024 * 1024]u8 = undefined;

fn handler(_: lambda.Context, _: []const u8) ![]const u8 {
    return &output;
}
