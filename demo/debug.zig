//! Returns the function’s metadata, environment variables and the provided payload.
//!
//! 🛑 WARNING 🛑 This demo may expose sensative data to the public.

const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.runHandler(handler);
}

fn handler(allocs: lambda.Allocators, context: lambda.Context, event: []const u8) anyerror![]const u8 {
    var str = try std.ArrayList(u8).initCapacity(allocs.arena, 1024);

    const writer = str.writer();
    try writer.print(
        "{{\"invoked arn\":\"{s}\",\"remaining (ms)\":{d},\"event\":{s},\"env\":",
        .{ context.invoked_arn, context.deadline_ms, event },
    );
    try std.json.stringify(context.env_reserved, .{}, writer);
    try writer.writeAll("}");

    return str.toOwnedSlice();
}
