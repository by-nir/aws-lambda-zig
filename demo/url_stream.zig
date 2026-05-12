//! Use Lambda URLs for response streaming of dynamic web content.
//!
//! 👉 Be sure to configure the Lambda function with URL enabled and RESPONSE_STREAM invoke mode.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handleStream(init, handler, .{});
}

/// 0.5 seconds (in nanoseconds)
const HALF_SEC = std.time.ns_per_s / 2;

fn handler(ctx: lambda.Context, event: []const u8, stream: lambda.Stream) !void {
    // Decode the Lambda URLs event.
    // We pass an arena allocator, so we don’t need to deinit.
    const request: lambda.url.Request = try .init(ctx.arena, event);

    const intro: []const u8 = blk: {
        // Use the request’s path to customize the response header:
        if (request.request_context.http.path) |path| if (path.len > 1) {
            const category = path[1..path.len];
            const format = "<h1>News &amp; Updates – Category: <em>{s}</em></h1>";
            break :blk try std.fmt.allocPrint(ctx.arena, format, .{category});
        };

        // Default homepage header
        break :blk "<h1>News &amp; Updates</h1>";
    };

    // Start a textual event stream with an initial HTML response:
    const writer = try lambda.url.openStream(ctx, stream, .{
        .status_code = .partial_content,
        .content_type = "text/html; charset=utf-8",
        .body = .{
            .textual = intro,
        },
        // We can set additional headers and cookies:
        // .headers = &.{ .{ .key = "Cache-Control", .value = "max-age=300, immutable" } },
        // .cookies = &.{ "cookie1=value1; Max-Age=86400; HttpOnly; Secure; SameSite=Lax" },
    });

    // Wait for half a second.
    try ctx.io.sleep(.fromMilliseconds(500), .awake);

    // Append multiple to the stream’s buffer without publishing to the client.
    try writer.writeAll("<h2>Update #1</h2>");
    try writer.print(
        "<p>Current epoch: <time>{d}</time></p>",
        .{currentEpochSeconds(ctx.io)},
    );

    // Publish the buffered data to the client.
    try stream.publish();
    try ctx.io.sleep(.fromMilliseconds(500), .awake);

    try writer.writeAll(
        \\<h2>Update #2</h2>
        \\<p>Current epoch: 🕰️</p>
    );
    try stream.publish();
    try ctx.io.sleep(.fromMilliseconds(500), .awake);

    // One last message to the client...
    try writer.print(
        \\<h2>Update #{d}</h2>
        \\<p>Current epoch: <time>{d}</time></p>
    , .{ 3, currentEpochSeconds(ctx.io) });
    try stream.publish();

    // We can optionally let the runtime know we have finished the response.
    // If we don't have more work to do, we can return without calling `close()`.
    try stream.close();

    // Then we can proceed to other work here...
}

fn currentEpochSeconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
