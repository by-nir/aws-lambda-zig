//! Returns an output larger than the Lambda limit.

const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.runHandler(handler);
}

// Max lambda payload size is 6MB.
const output: [8 * 1024 * 1024]u8 = undefined;

fn handler(_: lambda.Allocators, _: lambda.Context, _: []const u8) anyerror![]const u8 {
    return &output;
}
