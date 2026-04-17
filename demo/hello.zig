//! Returns a short message.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(_: lambda.Context, _: []const u8) ![]const u8 {
    return "Hello from the AWS Lambda Runtime for Zig!";
}
