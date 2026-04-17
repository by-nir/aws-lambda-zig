const std = @import("std");
const srv = @import("serve.zig");
const Server = srv.Server;
const log = @import("../utils/log.zig").runtime;

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
            var state: Stream.State = .pending;

            handlerFn(ctx, event, .{
                .server = server,
                .stream = &stream,
                .state = &state,
            }) catch |err| {
                if (state == .pending) {
                    server.respondFailure(err, @errorReturnTrace()) catch {};
                    return .abort;
                } else {
                    log.err("The handler returned an error after opening a stream: {s}", .{@errorName(err)});
                }
            };

            switch (state) {
                .pending => {
                    server.respondFailure(error.NoResponse, @errorReturnTrace()) catch {};
                    return .abort;
                },
                .active => return if (stream.close(null)) .success else |_| .abort,
                .end => return .success,
            }
        }
    }.f);
}

pub const Stream = struct {
    server: *Server,
    stream: *Server.Stream,
    state: *State,

    const State = enum {
        pending,
        active,
        end,
    };

    /// Start streaming a response of a specified content type.
    pub fn open(self: @This(), content_type: []const u8) !*std.Io.Writer {
        return self.openPrint(content_type, "", {});
    }

    /// Start streaming a response of a specified HTTP content type and initial body payload.
    ///
    /// Warning: Note that `prelude_fmt` expects raw HTTP as it merely appends the bytes to the HTTP request.
    /// The user MUST format the payload with proper HTTP semantics (or use a Event Encoder).
    pub fn openPrint(
        self: @This(),
        content_type: []const u8,
        comptime prelude_fmt: []const u8,
        prelude_args: anytype,
    ) !*std.Io.Writer {
        if (self.state.* != .pending) return error.ReopeningStream;

        std.debug.assert(content_type.len > 0);
        self.stream.* = try self.server.streamSuccess(content_type, prelude_fmt, prelude_args);

        self.state.* = .active;
        return self.stream.writer();
    }

    /// Send a partial response buffer to the client.
    ///
    /// If an error occurs, the stream is closed and the handler should return as soon as possible.
    pub fn publish(self: Stream) !void {
        if (self.state.* != .active) return error.InactiveStream;
        try self.stream.flush();
    }

    /// **Optional**.
    /// End the response stream while the handler proceeds to do other work.
    pub fn close(self: @This()) !void {
        if (self.state.* != .active) return;
        try self.stream.close(null);
        self.state.* = .end;
    }

    // TODO: Further investigate why Lambda’s Runtime API seems to ignore the trailer headers.
    // /// End the response stream with a trailing HTTP error.
    // pub fn closeWithError(self: Stream, err: anyerror, message: []const u8) !void {
    //     if (self.state.* != .active) return;
    //     try self.stream.close(.{
    //         .type = err,
    //         .message = message,
    //     });
    //     self.state.* = .end;
    // }
};
