//! Stream a response to the client.
//!
//! 👉 Be sure to configure the Lambda function with URL enabled and RESPONSE_STREAM invoke mode.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handleStream(init, handler, .{});
}

/// 0.5 seconds (in nanoseconds)
const HALF_SEC = std.time.ns_per_s / 2;

fn handler(ctx: lambda.Context, _: []const u8, stream: lambda.Stream) !void {
    // Start a textual event stream with a prelude body.
    // Use `stream.open("text/event-stream")` instead when a prelude body is not needed.
    const writer = try stream.openPrint("text/event-stream", "Loading {d} messages...\n\n", .{3});

    // Wait for half a second.
    try ctx.io.sleep(.fromMilliseconds(500), .awake);

    // Append multiple to the stream’s buffer without publishing to the client.
    try writer.writeAll("id: 0\n");
    try writer.print("data: This is message number {d}\n\n", .{1});

    // Send the buffered response to the client.
    try stream.publish();
    try ctx.io.sleep(.fromMilliseconds(500), .awake);

    try writer.writeAll("id: 1\ndata: This is message number 2\n\n");

    try stream.publish();
    try ctx.io.sleep(.fromMilliseconds(500), .awake);

    // One last message to the client...
    try writer.print("id: {d}\ndata: This is message number {d}\n\n", .{ 2, 3 });
    try stream.publish();

    // We can optionally let the runtime know we have finished the response.
    // If we don't have more work to do, we can return without calling `close()`.
    try stream.close();

    // Then we can proceed to other work here...
}
