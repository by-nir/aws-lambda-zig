const std = @import("std");
const log = @import("../utils/log.zig").runtime;
const srv = @import("serve.zig");
const Server = srv.Server;

pub const Options = srv.Options;
pub const Context = @import("context.zig").Context;

const AsyncHandlerFn = fn (ctx: Context, event: []const u8) anyerror!void;
const SyncHandlerFn = fn (ctx: Context, event: []const u8) anyerror![]const u8;
const StreamingHandlerFn = fn (ctx: Context, event: []const u8, stream: Stream) anyerror!void;

fn serve(options: Options, processorFn: srv.ProcessorFn) void {
    // Initialize the server.
    // If it fails we can return since the server already logged the error.
    var server: Server = undefined;
    Server.init(&server, options) catch return;

    // Run the event loop until an error occurs or the process is terminated.
    defer server.deinit();
    server.listen(processorFn);
}

/// The entry point for a synchronous AWS Lambda function.
/// Accepts a handler function that will process each event separetly.
pub fn handleSync(comptime handlerFn: SyncHandlerFn, options: Options) void {
    serve(options, struct {
        fn f(server: *Server, ctx: Context, event: []const u8) srv.InvocationResult {
            if (handlerFn(ctx, event)) |output| {
                server.respondSuccess(output) catch return .abort;
            } else |e| {
                server.respondFailure(e, @errorReturnTrace()) catch return .abort;
            }

            return .success;
        }
    }.f);
}

/// The entry point for an asynchronous AWS Lambda function.
/// Accepts a handler function that will process each event separetly.
pub fn handleAsync(comptime handlerFn: AsyncHandlerFn, options: Options) void {
    serve(options, struct {
        fn f(server: *Server, ctx: Context, event: []const u8) srv.InvocationResult {
            if (handlerFn(ctx, event)) {
                server.respondSuccess("") catch return .abort;
            } else |e| {
                server.respondFailure(e, @errorReturnTrace()) catch return .abort;
            }

            return .success;
        }
    }.f);
}

/// The entry point for a response streaming AWS Lambda function.
/// Accepts a streaming handler function that will process each event separetly.
pub fn handleStreaming(comptime handlerFn: StreamingHandlerFn, options: Options) void {
    serve(options, struct {
        fn f(server: *Server, ctx: Context, event: []const u8) srv.InvocationResult {
            var stream: Server.Stream = undefined;
            var stream_ctx: StreamingContext = .{};

            handlerFn(ctx, event, .{
                .server = server,
                .stream = &stream,
                .context = &stream_ctx,
            }) catch |err| {
                if (stream_ctx.state == .pending) {
                    server.respondFailure(err, @errorReturnTrace()) catch return .abort;
                    return stream_ctx.invocationResult();
                } else {
                    log.err("The handler returned an error after opening a stream: {s}", .{@errorName(err)});
                }
            };

            switch (stream_ctx.state) {
                .pending => server.respondFailure(error.NoResponse, null) catch return .abort,
                .active => stream.close(null) catch return .abort,
                .end => {},
            }

            return stream_ctx.invocationResult();
        }
    }.f);
}

const StreamingContext = struct {
    state: State = .pending,
    fail_source: Source = .none,

    const State = enum { pending, active, end };
    const Source = enum { none, handler, runtime };

    pub fn invocationResult(self: StreamingContext) srv.InvocationResult {
        return switch (self.fail_source) {
            .none, .handler => .success,
            .runtime => .abort,
        };
    }
};

pub const Stream = struct {
    server: *Server,
    stream: *Server.Stream,
    context: *StreamingContext,

    pub const Error = error{ ClosedStream, RuntimeFail };
    pub const WriterError = Error || Server.Stream.Writer.Error;
    pub const Writer = std.io.Writer(Stream, WriterError, internalWrite);

    /// Start the response streaming of a specified content type.
    /// Calling open again after it has already been called is a non-op.
    pub fn open(self: Stream, content_type: []const u8) Error!void {
        try self.openWith(content_type, "", {});
    }

    /// Start the response streaming of a specified HTTP content type and initial body payload.
    /// Calling open again after it has already been called is a non-op.
    ///
    /// Warning: Note that `raw_http_prelude` expects raw HTTP as it merely appends the bytes to the HTTP request.
    /// The user MUST format the payload with proper HTTP semantics (or use a Event Encoder).
    pub fn openWith(
        self: Stream,
        content_type: []const u8,
        comptime raw_http_prelude: []const u8,
        args: anytype,
    ) Error!void {
        if (self.context.state != .pending or self.context.fail_source == .runtime) return;

        std.debug.assert(content_type.len > 0);
        self.stream.* = self.server.streamSuccess(content_type, raw_http_prelude, args) catch {
            return self.runtimeFailiure();
        };
        self.context.state = .active;
    }

    /// Append to the response buffer and send it the client.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn publish(self: Stream, payload: []const u8) WriterError!void {
        try self.write(payload);
        try self.flush();
    }

    /// Append to the response buffer.
    /// Call `flush()` to send the buffer to the client.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn write(self: Stream, payload: []const u8) WriterError!void {
        return self.stream.writer().writeAll(payload);
    }

    /// Writer for appending to the response buffer.
    /// Call `flush()` to send the buffer to the client.
    ///
    /// Assumes the stream is still active as long as the writer is used.
    pub fn writer(self: Stream) Writer {
        return .{ .context = self };
    }

    fn internalWrite(self: Stream, bytes: []const u8) WriterError!usize {
        if (self.isActive()) {
            return self.stream.writer().write(bytes) catch |err| {
                log.err("Writing to the stream’s buffer failed: {s}", .{@errorName(err)});
                return self.runtimeFailiure();
            };
        } else {
            return error.ClosedStream;
        }
    }

    /// Send the response buffer to the client.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn flush(self: Stream) Error!void {
        if (!self.isActive()) return error.ClosedStream;
        self.stream.flush() catch return self.runtimeFailiure();
    }

    /// **Optional**, end the response stream and proceed to do other work in the handler.
    pub fn close(self: Stream) Error!void {
        if (!self.isActive()) return error.ClosedStream;

        self.context.state = .end;
        self.stream.close(null) catch return self.runtimeFailiure();
    }

    // TODO: Further investigate why Lambda’s Runtime API seems to ignore the trailer headers.
    // /// End the response stream with a trailing HTTP error.
    // pub fn closeWithError(self: Stream, err: anyerror, message: []const u8) Error!void {
    //     if (!self.isActive()) return error.ClosedStream;
    //
    //     self.context.state = .end;
    //     self.stream.close(.{
    //         .type = err,
    //         .message = message,
    //     }) catch {
    //         return self.runtimeFailiure();
    //     };
    // }

    fn isActive(self: Stream) bool {
        return self.context.state == .active and self.context.fail_source != .runtime;
    }

    fn runtimeFailiure(self: Stream) error{RuntimeFail} {
        self.context.fail_source = .runtime;
        return error.RuntimeFail;
    }
};
