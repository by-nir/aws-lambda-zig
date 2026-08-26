//! End-to-end tests for the runtime’s event loop.
//!
//! Each test scripts a fake Runtime API with `Tester`, runs a real entry point
//! against it, and checks what the runtime posted back.
const std = @import("std");
const testing = std.testing;
const Tester = @import("Tester.zig");
const api = @import("../runtime/api.zig");
const hdl = @import("../runtime/handle.zig");
const HttpClient = @import("../utils/Http.zig");

const URL_BASE = "/2018-06-01/runtime/";

var keep_len: usize = 0;
/// Anything the handler sees is backed by the invocation arena, which the
/// runtime frees once the event loop ends. Copy what a test looks at later.
var keep_buffer: [1024]u8 = undefined;

fn keep(text: []const u8) []const u8 {
    const start = keep_len;
    keep_len += text.len;
    const copy = keep_buffer[start..keep_len];
    @memcpy(copy, text);
    return copy;
}

/// What the handler saw during the last invocation.
var seen: struct {
    events: usize = 0,
    payload: []const u8 = "",
    request_id: []const u8 = "",
    xray_trace: []const u8 = "",
    invoked_arn: []const u8 = "",
    deadline_ms: u64 = 0,
} = .{};

fn resetSeen() void {
    seen = .{};
    keep_len = 0;
}

test "handle: posts the handler’s output" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-1", .payload = "\"hello\"" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), echoHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-1/response");
    try tester.expectBody(0, "\"hello\"");
}

fn echoHandler(_: hdl.Context, event: []const u8) ![]const u8 {
    seen.events += 1;
    return event;
}

test "handleWriter: posts what the handler wrote" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-w", .payload = "\"ignored\"" },
    });
    defer tester.deinit();

    hdl.handleWriter(tester.processInit(), writerHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-w/response");
    try tester.expectBody(0, "part 1 and part 2");
}

fn writerHandler(_: hdl.Context, _: []const u8, response: *hdl.ResponseWriter) !void {
    const w = response.writer();
    try w.writeAll("part 1");
    try w.print(" and part {d}", .{2});
}

test "handleWriter: an early send is not sent twice" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-early" },
    });
    defer tester.deinit();

    hdl.handleWriter(tester.processInit(), earlySendHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectBody(0, "sent early");
}

fn earlySendHandler(_: hdl.Context, _: []const u8, response: *hdl.ResponseWriter) !void {
    try response.writer().writeAll("sent early");
    try response.send();

    // The handler may keep working after the response was sent.
    try testing.expect(response.isSent());
}

test "handleAsync: posts an empty response" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-a" },
    });
    defer tester.deinit();

    hdl.handleAsync(tester.processInit(), asyncHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-a/response");
    try tester.expectBody(0, "");
}

fn asyncHandler(_: hdl.Context, _: []const u8) !void {}

test "handle: a handler error is posted to the error URL" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-bad" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), failingHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-bad/error");

    const post = try tester.post(0);
    try testing.expectEqualStrings(
        "Handler.KaBoOoOm",
        post.header("Lambda-Runtime-Function-Error-Type").?,
    );
    try testing.expect(std.mem.containsAtLeast(u8, post.body, 1, "Handler.KaBoOoOm"));
}

fn failingHandler(_: hdl.Context, _: []const u8) ![]const u8 {
    return error.KaBoOoOm;
}

test "handleWriter: a handler error is posted to the error URL" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-bad-w" },
    });
    defer tester.deinit();

    hdl.handleWriter(tester.processInit(), failingWriterHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-bad-w/error");
}

fn failingWriterHandler(_: hdl.Context, _: []const u8, response: *hdl.ResponseWriter) !void {
    try response.writer().writeAll("never sent");
    return error.KaBoOoOm;
}

test "handle: keeps serving after an error is reported" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-1" },
        .{ .request_id = "id-2" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), failingHandler, .{});

    // One error report per event; a handler error must not end the instance.
    try tester.expectPostCount(2);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-1/error");
    try tester.expectPath(1, URL_BASE ++ "invocation/id-2/error");
}

test "handle: a container error from the API ends the event loop" {
    resetSeen();

    var tester: Tester = undefined;
    // With no events to serve, the very first request for the next event is
    // answered with HTTP 500.
    try tester.init(testing.allocator, &.{});
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), echoHandler, .{});

    // The runtime exits promptly: no handler call, nothing posted back.
    try testing.expectEqual(0, seen.events);
    try tester.expectPostCount(0);
}

test "handle: a container error while posting a response ends the loop" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-1", .reply_status = .internal_server_error },
        .{ .request_id = "id-2" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), echoHandler, .{});

    // HTTP 500 means the container is done. The runtime stops instead of
    // asking for the second event.
    try testing.expectEqual(1, seen.events);
    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-1/response");
}

test "handle: a container error while reporting an error ends the loop" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-1", .reply_status = .internal_server_error },
        .{ .request_id = "id-2" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), failingHandler, .{});

    try testing.expectEqual(0, seen.events);
    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-1/error");
}

test "handle: serves the events in order" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-1", .payload = "\"one\"" },
        .{ .request_id = "id-2", .payload = "\"two\"" },
        .{ .request_id = "id-3", .payload = "\"three\"" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), echoHandler, .{});

    try tester.expectPostCount(3);
    try testing.expectEqual(3, seen.events);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-1/response");
    try tester.expectBody(0, "\"one\"");
    try tester.expectPath(2, URL_BASE ++ "invocation/id-3/response");
    try tester.expectBody(2, "\"three\"");
}

test "handle: keeps serving when the API rejects a response" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-big", .reply_status = .payload_too_large },
        .{ .request_id = "id-ok" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), echoHandler, .{});

    try tester.expectPostCount(2);
    try testing.expectEqual(2, seen.events);
}

test "handle: the context carries the event’s metadata" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{
            .request_id = "id-meta",
            .payload = "{\"key\":\"value\"}",
            .xray_trace = "trace-meta",
            .invoked_arn = "arn-meta",
            .deadline_ms = 1_700_000_000_000,
        },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), metaHandler, .{});

    try tester.expectPostCount(1);
    try testing.expectEqualStrings("{\"key\":\"value\"}", seen.payload);
    try testing.expectEqualStrings("id-meta", seen.request_id);
    try testing.expectEqualStrings("trace-meta", seen.xray_trace);
    try testing.expectEqualStrings("arn-meta", seen.invoked_arn);
    try testing.expectEqual(1_700_000_000_000, seen.deadline_ms);
}

fn metaHandler(ctx: hdl.Context, event: []const u8) ![]const u8 {
    seen.events += 1;
    seen.payload = keep(event);
    seen.request_id = keep(ctx.request.id);
    seen.xray_trace = keep(ctx.request.xray_trace);
    seen.invoked_arn = keep(ctx.request.invoked_arn);
    seen.deadline_ms = ctx.request.deadline_ms;
    return "";
}

test "handle: the trace environment value follows each invocation" {
    resetSeen();

    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-1", .xray_trace = "trace-one" },
        .{ .request_id = "id-2", .xray_trace = "trace-two" },
    });
    defer tester.deinit();

    hdl.handleSync(tester.processInit(), traceHandler, .{});

    try testing.expectEqual(2, seen.events);
    try tester.expectPostCount(2);
    try tester.expectBody(0, "trace-one");
    try tester.expectBody(1, "trace-two");
}

fn traceHandler(ctx: hdl.Context, _: []const u8) ![]const u8 {
    seen.events += 1;

    // The environment value must carry this invocation’s trace, not the one
    // before it.
    const from_env = ctx.env("_X_AMZN_TRACE_ID") orelse return error.MissingTrace;
    try testing.expectEqualStrings(ctx.request.xray_trace, from_env);
    return from_env;
}

test "handleStream: streams a chunked response" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-s" },
    });
    defer tester.deinit();

    hdl.handleStreaming(tester.processInit(), streamHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-s/response");

    const post = try tester.post(0);
    try testing.expect(post.chunked);
    try testing.expectEqualStrings(
        "streaming",
        post.header("Lambda-Runtime-Function-Response-Mode").?,
    );
    try testing.expectEqualStrings("text/plain", post.header("content-type").?);
    try testing.expectEqualStrings("first\nsecond\nthird\n", post.body);

    // Closing without an error sends no trailers.
    try testing.expectEqual(0, post.trailers_raw.len);
}

fn streamHandler(_: hdl.Context, _: []const u8, stream: hdl.Stream) !void {
    var buffer: [64]u8 = undefined;
    const writer = try stream.open(&buffer, "text/plain");

    try writer.writeAll("first\n");
    try stream.publish();

    try writer.writeAll("second\n");
    try writer.writeAll("third\n");
    try stream.publish();

    try stream.close();
}

test "handleStream: a handler error before opening is posted to the error URL" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{
        .{ .request_id = "id-s-bad" },
    });
    defer tester.deinit();

    hdl.handleStreaming(tester.processInit(), failingStreamHandler, .{});

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-s-bad/error");
}

fn failingStreamHandler(_: hdl.Context, _: []const u8, _: hdl.Stream) !void {
    return error.KaBoOoOm;
}

test "api: an init error is posted to the init error URL" {
    var tester: Tester = undefined;
    try tester.init(testing.allocator, &.{});
    defer tester.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var client: HttpClient = undefined;
    try HttpClient.init(&client, testing.allocator, tester.origin(), threaded.io());
    defer client.deinit();

    _ = try api.sendInitFail(arena.allocator(), &client, .{
        .type = error.BadHandlerName,
        .message = "The handler is missing.",
    });

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "init/error");

    const post = try tester.post(0);
    try testing.expectEqualStrings(
        "Runtime.BadHandlerName",
        post.header("Lambda-Runtime-Function-Error-Type").?,
    );
    try testing.expect(std.mem.containsAtLeast(u8, post.body, 1, "Runtime.BadHandlerName"));
}

test "api: closing a stream with an error sends trailers" {
    const gpa = testing.allocator;

    var tester: Tester = undefined;
    try tester.init(gpa, &.{});
    defer tester.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var client: HttpClient = undefined;
    try HttpClient.init(&client, gpa, tester.origin(), threaded.io());
    defer client.deinit();

    // Only `streamInvocationClose` sends trailers, and only when the handler
    // failed after the stream was already open. No entry point reaches it
    // today, so the test drives the API directly.
    var buffer: [256]u8 = undefined;
    var request, var body = try api.streamInvocationOpen(
        arena.allocator(),
        &client,
        &buffer,
        "id-trailer",
        "text/plain",
        "",
        {},
    );

    try body.writer.writeAll("partial output");
    try body.writer.flush();

    _ = try api.streamInvocationClose(arena.allocator(), &request, &body, .{
        .type = error.KaBoOoOm,
        .message = "The handler failed mid-stream.",
    });

    try tester.expectPostCount(1);
    try tester.expectPath(0, URL_BASE ++ "invocation/id-trailer/response");

    const post = try tester.post(0);
    try testing.expect(post.chunked);
    try testing.expectEqualStrings("partial output", post.body);
    try testing.expectEqualStrings(
        "Handler.KaBoOoOm",
        post.trailer("Lambda-Runtime-Function-Error-Type").?,
    );

    // The error body travels as standard base64.
    const encoded = post.trailer("Lambda-Runtime-Function-Error-Body").?;
    var decoded: [256]u8 = undefined;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try std.base64.standard.Decoder.decode(decoded[0..decoded_len], encoded);
    try testing.expectEqualStrings(
        \\{"errorType":"Handler.KaBoOoOm","errorMessage":"The handler failed mid-stream.","stackTrace":[]}
    , decoded[0..decoded_len]);
}

test "init: gives up when the API origin is missing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var env_map: std.process.Environ.Map = .init(testing.allocator);
    defer env_map.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // The runtime logs the failure and returns instead of running an event loop.
    hdl.handleSync(.{
        .minimal = .{ .environ = .empty, .args = .{ .vector = &.{} } },
        .arena = &arena,
        .gpa = testing.allocator,
        .io = threaded.io(),
        .environ_map = &env_map,
        .preopens = .empty,
    }, echoHandler, .{});
}
