//! Stream a response to the client and eventually fail.
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

    // Transmit an error to the client. This will end the stream.
    try stream.fail(
        error.KaBoOoOm,
        "This error is passed to the client...\n",
    );
}
