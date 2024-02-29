//! Returns the provided payload.

const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.runHandler(handler);
}

fn handler(_: lambda.Allocators, _: *const lambda.Context, event: []const u8) anyerror![]const u8 {
    return event;
}
