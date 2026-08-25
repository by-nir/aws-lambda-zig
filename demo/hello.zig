//! Writes a short message with a response writer.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handleWriter(init, handler, .{});
}

fn handler(_: lambda.Context, _: []const u8, response: *lambda.ResponseWriter) !void {
    try response.writer().writeAll("Hello from the AWS Lambda Runtime for Zig!");
}
