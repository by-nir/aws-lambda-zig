//! Returns an output larger than the Lambda limit.
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.handle(handler);
}

// Max lambda payload size is 6MB.
const output: [8 * 1024 * 1024]u8 = undefined;

fn handler(_: lambda.Allocators, _: *const lambda.Context, _: []const u8) ![]const u8 {
    return &output;
}
