//! Returns the provided payload.

const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.serve(handler);
}

fn handler(_: lambda.Allocators, _: *const lambda.Context, event: []const u8) ![]const u8 {
    return event;
}
