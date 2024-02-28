//! Prints the provdedid payload.

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.runHandler(handler);
}

fn handler(_: lambda.Allocators, _: lambda.Context, event: []const u8) anyerror![]const u8 {
    return event;
}
