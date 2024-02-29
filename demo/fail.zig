//! Always returns an error
//!
//! The runtime logs the error to _CloudWatch_.

const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.runHandler(handler);
}

noinline fn handler(_: lambda.Allocators, _: *const lambda.Context, _: []const u8) anyerror![]const u8 {
    return error.KaBoOoOm;
}
