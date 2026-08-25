//! An in-process fake of the AWS Lambda Runtime API.
//!
//! The tester listens on the loopback interface and serves a script of
//! invocation events from a background thread. A test points the runtime at it
//! and runs the real event loop against it.
//!
//! ```zig
//! var tester: Tester = undefined;
//! try tester.init(std.testing.allocator, &.{
//!     .{ .request_id = "id-1", .payload = "\"hello\"" },
//! });
//! defer tester.deinit();
//!
//! handleSync(tester.processInit(), myHandler, .{});
//!
//! try tester.expectPostCount(1);
//! try tester.expectPath(0, "/2018-06-01/runtime/invocation/id-1/response");
//! ```
//!
//! The runtime asks for the next event until the API fails. Once the script is
//! used up, the tester answers HTTP 500, which is the status the Runtime API
//! uses to tell a runtime to exit. That is what ends the event loop and returns
//! control to the test.

const std = @import("std");
const net = std.Io.net;
const testing = std.testing;

const ENV_ORIGIN = "AWS_LAMBDA_RUNTIME_API";

/// The reply the API sends when the runtime posts an event’s result back.
const REPLY_ACCEPTED =
    \\{"status":"OK"}
;
const REPLY_FAILED =
    \\{"errorMessage":"Scripted failure.","errorType":"TesterError"}
;

/// One invocation event the tester serves to the runtime.
pub const Event = struct {
    /// AWS request ID. It is part of the URL the runtime posts the result to.
    request_id: []const u8 = "test-request",

    /// The event’s raw payload.
    payload: []const u8 = "{}",

    /// X-Ray trace ID.
    xray_trace: []const u8 = "test-trace",

    /// The function ARN requested.
    invoked_arn: []const u8 = "test-arn",

    /// Function execution deadline, in milliseconds since the _Unix epoch_.
    deadline_ms: u64 = 0,

    /// The status the API returns when the runtime posts this event’s result.
    /// The real API returns `202 Accepted`.
    reply_status: std.http.Status = .accepted,
};

/// One request the runtime sent to the tester.
pub const Record = struct {
    method: std.http.Method,

    /// The request’s URL path.
    path: []const u8,

    /// The request’s raw head, including the request line.
    head: []const u8,

    /// The request’s body. Chunked bodies are joined.
    body: []const u8,

    /// The request’s raw trailers. Empty when the request had none.
    trailers_raw: []const u8,

    /// Whether the body used chunked transfer encoding.
    chunked: bool,

    /// Returns the value of a request header, ignoring the name’s case.
    pub fn header(self: Record, name: []const u8) ?[]const u8 {
        var it: std.http.HeaderIterator = .init(self.head);
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Returns the value of a request trailer, ignoring the name’s case.
    ///
    /// Trailers are parsed here instead of with `std.http.HeaderIterator`,
    /// because the iterator skips the first line of the block it is given and
    /// a trailer block has no first line.
    pub fn trailer(self: Record, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.trailers_raw, "\r\n");
        while (lines.next()) |line| {
            const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..separator], name)) continue;
            return std.mem.trim(u8, line[separator + 1 ..], " \t");
        }
        return null;
    }

    fn deinit(self: Record, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.head);
        gpa.free(self.body);
        gpa.free(self.trailers_raw);
    }
};

gpa: std.mem.Allocator,
threaded: std.Io.Threaded,
io: std.Io,

listener: net.Server,
address: net.IpAddress,
thread: std.Thread,
/// Tells the background thread to stop accepting connections.
stopping: std.atomic.Value(bool),
stopped: bool,

/// The events left to serve.
script: []const Event,
/// How many events were served so far.
served: usize,
/// The requests the runtime sent back.
records: std.ArrayList(Record),
/// The first error the background thread ran into, if any.
thread_err: ?anyerror,

/// Backs the process init value the runtime is given.
arena: std.heap.ArenaAllocator,
env_map: std.process.Environ.Map,

/// Starts the fake API. The tester holds pointers to itself, so it must not be
/// copied after this call.
pub fn init(self: *@This(), gpa: std.mem.Allocator, script: []const Event) !void {
    self.gpa = gpa;
    self.script = script;
    self.served = 0;
    self.records = .empty;
    self.thread_err = null;
    self.stopping = .init(false);
    self.stopped = false;

    self.threaded = std.Io.Threaded.init(gpa, .{});
    errdefer self.threaded.deinit();
    self.io = self.threaded.io();

    // Port 0 asks the operating system for a free port; the socket reports back
    // the port it was given.
    const wanted: net.IpAddress = .{ .ip4 = .loopback(0) };
    self.listener = try wanted.listen(self.io, .{});
    errdefer self.listener.deinit(self.io);
    self.address = self.listener.socket.address;

    self.arena = .init(gpa);
    errdefer self.arena.deinit();

    self.env_map = .init(gpa);
    errdefer self.env_map.deinit();

    var origin_buffer: [32]u8 = undefined;
    const origin_text = try std.fmt.bufPrint(&origin_buffer, "127.0.0.1:{d}", .{
        self.address.getPort(),
    });
    try self.env_map.put(ENV_ORIGIN, origin_text);

    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn deinit(self: *@This()) void {
    self.stop();

    for (self.records.items) |record| record.deinit(self.gpa);
    self.records.deinit(self.gpa);

    self.env_map.deinit();
    self.arena.deinit();
    self.threaded.deinit();
    self.* = undefined;
}

/// Stops serving and waits for the background thread. Safe to call more than
/// once.
pub fn stop(self: *@This()) void {
    if (self.stopped) return;
    self.stopped = true;

    self.stopping.store(true, .release);

    // `accept` blocks until a client shows up, so wake it with a throwaway
    // connection instead of closing the socket underneath it.
    if (net.IpAddress.connect(&self.address, self.io, .{ .mode = .stream })) |stream| {
        stream.close(self.io);
    } else |_| {}

    self.thread.join();
    self.listener.deinit(self.io);
}

/// The process init value to pass to a runtime entry point.
/// It points the runtime at the tester through `AWS_LAMBDA_RUNTIME_API`.
pub fn processInit(self: *@This()) std.process.Init {
    return .{
        .minimal = .{ .environ = .empty, .args = .{ .vector = &.{} } },
        .arena = &self.arena,
        .gpa = self.gpa,
        .io = self.io,
        .environ_map = &self.env_map,
        .preopens = .empty,
    };
}

/// The host and port the fake API listens on, in the form the
/// `AWS_LAMBDA_RUNTIME_API` environment value uses.
pub fn origin(self: *@This()) []const u8 {
    return self.env_map.get(ENV_ORIGIN).?;
}

/// Everything the runtime posted back, in the order it was received.
/// Requests for the next event are not included.
///
/// Stops the background thread, so call it once the event loop ended.
pub fn posts(self: *@This()) []const Record {
    self.stop();
    return self.records.items;
}

/// Fails when the background thread ran into an error.
pub fn expectNoError(self: *@This()) !void {
    self.stop();
    if (self.thread_err) |err| {
        std.debug.print("The tester’s server failed: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    }
}

/// Fails unless the runtime posted back exactly `count` times.
pub fn expectPostCount(self: *@This(), count: usize) !void {
    try self.expectNoError();
    try testing.expectEqual(count, self.posts().len);
}

/// Fails unless the post at `index` went to `path`.
pub fn expectPath(self: *@This(), index: usize, path: []const u8) !void {
    const record = try self.post(index);
    try testing.expectEqual(std.http.Method.POST, record.method);
    try testing.expectEqualStrings(path, record.path);
}

/// Fails unless the body of the post at `index` equals `body`.
pub fn expectBody(self: *@This(), index: usize, body: []const u8) !void {
    const record = try self.post(index);
    try testing.expectEqualStrings(body, record.body);
}

/// The post at `index`, or a test failure when there is no such post.
pub fn post(self: *@This(), index: usize) !Record {
    try self.expectNoError();
    const items = self.posts();
    if (index >= items.len) {
        std.debug.print(
            "Expected at least {d} posts, found {d}.\n",
            .{ index + 1, items.len },
        );
        return error.TestUnexpectedResult;
    }
    return items[index];
}

fn run(self: *@This()) void {
    while (!self.stopping.load(.acquire)) {
        const stream = self.listener.accept(self.io) catch |err| {
            self.captureError(err);
            return;
        };
        defer stream.close(self.io);

        if (self.stopping.load(.acquire)) return;

        // A failed connection is not fatal: the runtime sees the failure, ends
        // its event loop, and the test carries on to its assertions.
        self.serve(stream) catch |err| self.captureError(err);
    }
}

fn captureError(self: *@This(), err: anyerror) void {
    switch (err) {
        // The runtime closes each connection after a single request.
        error.HttpConnectionClosing, error.EndOfStream => {},
        else => if (self.thread_err == null) {
            self.thread_err = err;
        },
    }
}

fn serve(self: *@This(), stream: net.Stream) !void {
    var recv_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &recv_buffer);
    var writer = stream.writer(self.io, &send_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);

    var request = try server.receiveHead();
    if (std.mem.endsWith(u8, request.head.target, "/invocation/next")) {
        return self.serveNext(&request);
    } else {
        return self.serveResult(&request);
    }
}

/// Serves the next scripted event, or ends the runtime’s event loop.
fn serveNext(self: *@This(), request: *std.http.Server.Request) !void {
    if (self.served == self.script.len) {
        // HTTP 500 tells the runtime to exit promptly.
        return request.respond(REPLY_FAILED, .{
            .status = .internal_server_error,
            .keep_alive = false,
        });
    }

    const event = self.script[self.served];
    self.served += 1;

    var deadline_buffer: [24]u8 = undefined;
    const deadline = try std.fmt.bufPrint(&deadline_buffer, "{d}", .{event.deadline_ms});

    return request.respond(event.payload, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "Lambda-Runtime-Aws-Request-Id", .value = event.request_id },
            .{ .name = "Lambda-Runtime-Trace-Id", .value = event.xray_trace },
            .{ .name = "Lambda-Runtime-Invoked-Function-Arn", .value = event.invoked_arn },
            .{ .name = "Lambda-Runtime-Deadline-Ms", .value = deadline },
        },
    });
}

/// Records a result the runtime posted back, then answers it.
fn serveResult(self: *@This(), request: *std.http.Server.Request) !void {
    const gpa = self.gpa;

    // Reading the body invalidates the head’s memory, so copy it first.
    const head = try gpa.dupe(u8, request.head_buffer);
    errdefer gpa.free(head);
    const path = try gpa.dupe(u8, request.head.target);
    errdefer gpa.free(path);

    const method = request.head.method;
    const chunked = request.head.transfer_encoding == .chunked;

    var body_buffer: [16 * 1024]u8 = undefined;
    const body_reader = request.readerExpectNone(&body_buffer);
    const body = try body_reader.allocRemaining(gpa, .unlimited);
    errdefer gpa.free(body);

    const trailers_raw = try gpa.dupe(u8, request.server.reader.trailers);
    errdefer gpa.free(trailers_raw);

    try self.records.append(gpa, .{
        .method = method,
        .path = path,
        .head = head,
        .body = body,
        .trailers_raw = trailers_raw,
        .chunked = chunked,
    });

    const status = self.replyStatus(path);
    return request.respond(
        if (status == .accepted) REPLY_ACCEPTED else REPLY_FAILED,
        .{ .status = status, .keep_alive = false },
    );
}

/// The status to answer a posted result with, as set by the served event.
fn replyStatus(self: *@This(), path: []const u8) std.http.Status {
    if (std.mem.endsWith(u8, path, "/init/error")) return .accepted;
    if (self.served == 0) return .accepted;
    return self.script[self.served - 1].reply_status;
}
