//! Returns a short message.
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.handle(handler, .{});
}

fn handler(_: lambda.Allocators, _: lambda.Context, _: []const u8) ![]const u8 {
    return "Hello from the AWS Lambda Runtime for Zig!";
}
