//! Force the Lambda function instance the terminate after returning a response.
//!
//! 🛑 Use with caution! Only use this method when you assume the function
//! won’t behave as expected in the following invocation.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, _: []const u8) ![]const u8 {
    // Request the Lambda execution environment to terminate the function
    // instance after returning the response to the client.
    ctx.forceTerminateAfterResponse();

    return "Crash in 3... 2... 1...";
}
