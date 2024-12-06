//! Stream a response to the client.
//!
//! 👉 _Be sure to enable streaming support in the function configuration._
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.handleStream(handler);
}

/// 0.5 seconds (in nanoseconds)
const HALF_SEC = 500_000_000;

fn handler(_: lambda.Allocators, _: lambda.Context, _: []const u8, stream: lambda.Stream) !void {
    // Start a textual event stream.
    try stream.open("text/event-stream");

    // Append multiple to the stream’s buffer without publishing to the client.
    try stream.write("id: 0\n");
    try stream.writeFmt("data: This is message number {d}\n\n", .{1});

    // Publish the buffered data to the client.
    try stream.flush();
    std.time.sleep(HALF_SEC);

    // Shortcut for both `write` and `flush` in one call.
    try stream.publish("id: 1\ndata: This is message number 2\n\n");
    std.time.sleep(HALF_SEC);

    // We can use zig’s standard formatting when writing and publishing.
    try stream.publishFmt("id: {d}\ndata: This is message number {d}\n\n", .{ 2, 3 });
    std.time.sleep(HALF_SEC);

    // We can optionally let the runtime know we have finished the response.
    // If we don't have more work to do, we can return without calling `close`.
    try stream.close();

    // Then we can proceed to other work.
    doSomeCleanup();
}

fn doSomeCleanup() void {
    // Some cleanup work...
}
