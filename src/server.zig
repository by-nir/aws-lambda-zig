const std = @import("std");
const lambda = @import("lambda.zig");
const Runtime = @import("Runtime.zig");

const HandlerFn = *const fn (
    allocs: lambda.Allocators,
    context: *const lambda.Context,
    /// The event’s JSON payload
    event: []const u8,
) anyerror![]const u8;

const StreamHandlerFn = *const fn (
    allocs: lambda.Allocators,
    context: *const lambda.Context,
    /// The event’s JSON payload
    event: []const u8,
    stream: Stream,
) anyerror!void;

fn serve(processor: Runtime.processorFn) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocs = lambda.Allocators{
        .gpa = gpa.allocator(),
        .arena = arena.allocator(),
    };

    var runtime = Runtime.init(allocs) catch return;
    defer runtime.deinit();

    // Run the event loop until an error occurs or the process is terminated.
    runtime.eventLoop(&arena, processor);
}

/// The entry point for an AWS Lambda function.
///
/// Accepts a const reference to a handler function that will process each event separetly.
pub fn serveBuffered(comptime handler: HandlerFn) void {
    serve(struct {
        fn f(rt: *Runtime, payload: []const u8) Runtime.InvocationResult {
            if (handler(rt.allocs, &rt.context, payload)) |output| {
                rt.respondSuccess(output) catch return .abort;
            } else |e| {
                rt.respondFailure(e, @errorReturnTrace()) catch return .abort;
            }

            return .success;
        }
    }.f);
}

/// The entry point for a streaming AWS Lambda function.
///
/// Accepts a const reference to a streaming handler function that will process each event separetly.
pub fn serveStreaming(comptime handler: StreamHandlerFn) void {
    serve(struct {
        fn f(runtime: *Runtime, payload: []const u8) Runtime.InvocationResult {
            var context: StreamingContext = .{};
            var stream: Runtime.Stream = undefined;

            handler(runtime.allocs, &runtime.context, payload, .{
                .runtime = runtime,
                .stream = &stream,
                .context = &context,
            }) catch |err| {
                if (context.state == .pending) {
                    runtime.respondFailure(err, @errorReturnTrace()) catch return .abort;
                    return context.invocationResult();
                }

                lambda.log_runtime.err(
                    "[Stream Processor] The handler returned an error after opening a stream: {s}",
                    .{@errorName(err)},
                );
            };

            switch (context.state) {
                .pending => runtime.respondFailure(error.NoResponse, null) catch return .abort,
                .active => stream.close(null) catch return .abort,
                .end => {},
            }

            return context.invocationResult();
        }
    }.f);
}

const StreamingContext = struct {
    state: State = .pending,
    fail_source: Source = .none,

    const State = enum { pending, active, end };
    const Source = enum { none, handler, runtime };

    pub fn invocationResult(self: StreamingContext) Runtime.InvocationResult {
        return switch (self.fail_source) {
            .none, .handler => .success,
            .runtime => .abort,
        };
    }
};

pub const Stream = struct {
    runtime: *Runtime,
    stream: *Runtime.Stream,
    context: *StreamingContext,

    pub const Error = error{
        ClosedStream,
        RuntimeFail,
    };

    /// Start the response stream with a given http content type.
    ///
    /// Calling open again after it has already been called is a non-op.
    pub fn open(self: Stream, content_type: []const u8) Error!void {
        if (self.context.state != .pending or self.context.fail_source == .runtime) return;

        std.debug.assert(content_type.len > 0);
        self.stream.* = self.runtime.streamSuccess(content_type) catch return self.runtimeFailiure();
        self.context.state = .active;
    }

    /// Append to the stream’s buffer.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn write(self: Stream, payload: []const u8) Error!void {
        if (self.isActive()) {
            self.stream.write(payload) catch return self.runtimeFailiure();
        } else {
            return error.ClosedStream;
        }
    }

    /// Append to the stream’s buffer.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn writeFmt(self: Stream, comptime format: []const u8, args: anytype) Error!void {
        if (self.isActive()) {
            self.stream.writeFmt(format, args) catch return self.runtimeFailiure();
        } else {
            return error.ClosedStream;
        }
    }

    /// Send the stream’s buffer to the client.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn flush(self: Stream) Error!void {
        if (self.isActive()) {
            self.stream.flush() catch return self.runtimeFailiure();
        } else {
            return error.ClosedStream;
        }
    }

    /// Append to the stream’s buffer and send it the client.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn publish(self: Stream, payload: []const u8) Error!void {
        try self.write(payload);
        try self.flush();
    }

    /// Append to the stream’s buffer and send it the client.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn publishFmt(self: Stream, comptime format: []const u8, args: anytype) Error!void {
        try self.writeFmt(format, args);
        try self.flush();
    }

    /// **Optional**, end the response stream and proceed to do other work in the handler.
    pub fn close(self: Stream) Error!void {
        if (!self.isActive()) return error.ClosedStream;

        self.context.state = .end;
        self.stream.close(null) catch return self.runtimeFailiure();
    }

    /// End the response stream with a **client-transmitted** error.
    pub fn closeWithError(self: Stream, err: anyerror, message: []const u8) Error!void {
        if (!self.isActive()) return error.ClosedStream;

        try self.write(message);
        self.context.state = .end;
        self.stream.close(.{
            .err_type = err,
            .message = message,
        }) catch {
            return self.runtimeFailiure();
        };
    }

    fn isActive(self: Stream) bool {
        return self.context.state == .active and self.context.fail_source != .runtime;
    }

    fn runtimeFailiure(self: Stream) Error!void {
        self.context.fail_source = .runtime;
        return error.RuntimeFail;
    }
};
