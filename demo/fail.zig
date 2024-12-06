//! Always returns an error
//!
//! The runtime logs the error to _CloudWatch_.
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.handle(handler);
}

noinline fn handler(_: lambda.Allocators, _: *const lambda.Context, _: []const u8) ![]const u8 {
    return error.KaBoOoOm;
}
