//! Stream a response to the client.
//!
//! 👉 _Be sure to enable streaming support in the function configuration._

const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.serveStream(handler);
}

/// 0.5 seconds
const WAIT_NS = 500_000_000;
const LoremIpsum = "Lorem ipsum dolor sit amet, consectetur adipiscing elit.";

fn handler(_: lambda.Allocators, _: *const lambda.Context, _: []const u8, stream: lambda.Channel) !void {
    // Start a plain-text response stream.
    try stream.open("text/event-stream");
    try stream.write(LoremIpsum);
    std.time.sleep(WAIT_NS);

    try stream.write("\n\n" ++ LoremIpsum);
    std.time.sleep(WAIT_NS);

    try stream.write("\n\n" ++ LoremIpsum);
    std.time.sleep(WAIT_NS);

    try stream.write("\n\n" ++ LoremIpsum);

    // We can let the runtime know we finished the response and then proceed to
    // other work. If we don't have more work to do, we can just return.
    try stream.close();

    cleanup();
}

fn cleanup() void {
    // Some cleanup code after we completed the response stream...
}
