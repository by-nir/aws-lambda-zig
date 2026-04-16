//! Always returns an error
//!
//! The runtime logs the error to _CloudWatch_.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

noinline fn handler(_: lambda.Context, _: []const u8) ![]const u8 {
    return error.KaBoOoOm;
}
