const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const lambda = @import("../lambda.zig");
const HttpClient = @import("../utils/Http.zig");

pub const ServerOptions = struct {};

pub const ProcessorFn = *const fn (server: *Server, payload: []const u8) InvocationResult;

pub const InvocationResult = enum {
    /// The runtime may process another event.
    success,
    /// The runtime should terminate the lambda instance.
    abort,
};

pub const Server = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    arena: std.heap.ArenaAllocator,
    context: lambda.Context,
    http: HttpClient,

    pub fn init(self: *Server, _: ServerOptions) !void {
        errdefer self.* = undefined;

        self.gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const gpa_alloc = self.gpa.allocator();
        errdefer _ = self.gpa.deinit();

        const child_alloc = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
        self.arena = std.heap.ArenaAllocator.init(child_alloc);
        const arena_alloc = self.arena.allocator();
        errdefer self.arena.deinit();

        self.context = lambda.Context.init(gpa_alloc) catch |err| {
            initFailed(arena_alloc, null, err, "Creating the runtime context failed");
            return err;
        };
        errdefer self.context.deinit(gpa_alloc);

        self.http = HttpClient.init(gpa_alloc, self.context.api_origin) catch |err| {
            initFailed(arena_alloc, null, err, "Creating a http client failed");
            return err;
        };
    }

    pub fn deinit(self: *Server) void {
        self.http.deinit();
        self.context.deinit(self.gpa.allocator());
        self.arena.deinit();
        _ = self.gpa.deinit();
    }

    fn initFailed(arena: Allocator, http: ?*HttpClient, err: anyerror, message: []const u8) void {
        logError("[Init] {s}: {s}", .{ message, @errorName(err) });
        const h2p = http orelse return;

        const request = api.ErrorRequest{
            .type = err,
            .message = message,
        };

        const result = api.sendInitFail(arena, h2p, request) catch |e| {
            logError("Sending the initialization’s error report failed: {s}", .{@errorName(e)});
            return;
        };

        switch (result) {
            .accepted => {},
            .forbidden => |e| {
                logError("Sending the initialization’s error report failed: {s}.\n{s}", .{ e.type, e.message });
            },
        }
    }

    /// Event loop – request and invocate events sequentially.
    pub fn listen(self: *Server, processor: ProcessorFn) void {
        while (true) {
            // Request the next event
            const next = api.sendInvocationNext(self.arena.allocator(), &self.http) catch |err| {
                logError("Requesting the next invocation failed: {s}", .{@errorName(err)});
                return;
            };

            // Handle the event
            switch (next) {
                // Failed retrieving the event
                .forbidden => |err| {
                    logError("Requesting the next invocation failed: {s}.\n{s}", .{ err.type, err.message });
                },

                // Process the event
                .success => |event| {
                    // Set up the event’s context
                    const ctx = &self.context;
                    ctx.request_id = event.request_id;
                    ctx.invoked_arn = event.invoked_arn;
                    ctx.deadline_ms = event.deadline_ms;
                    ctx.client_context = event.client_context;
                    ctx.cognito_identity = event.cognito_identity;
                    ctx.xray_trace = event.xray_trace;
                    defer ctx.xray_trace = &[_]u8{};

                    if (processor(self, event.payload) == .abort) return;
                },
            }

            // Clean-up ahead of the next invocation
            _ = self.arena.reset(.retain_capacity);
        }
    }

    pub fn respondFailure(self: *Server, err: anyerror, trace: ?*std.builtin.StackTrace) !void {
        if (trace) |t| {
            logError("The handler returned an error `{s}`.{?}", .{ @errorName(err), t });
        } else {
            logError("The handler returned an error `{s}`.", .{@errorName(err)});
        }

        const request = api.ErrorRequest{
            .type = err,
            .message = "The handler returned an error response.",
        };

        const result = api.sendInvocationFail(
            self.arena.allocator(),
            &self.http,
            self.context.request_id,
            request,
        ) catch |e| {
            return logErrorName("Sending the invocation’s error report failed: {s}", e);
        };

        switch (result) {
            .accepted => {},
            .bad_request, .forbidden => |e| {
                logError("Sending the invocation’s error report failed: {s}.\n{s}", .{ e.type, e.message });
            },
        }
    }

    pub fn respondSuccess(self: *Server, output: []const u8) !void {
        const result = api.sendInvocationSuccess(
            self.arena.allocator(),
            &self.http,
            self.context.request_id,
            output,
        ) catch |err| {
            return logErrorName("Sending the invocation’s output failed: {s}", err);
        };

        switch (result) {
            .accepted => {},
            .bad_request, .forbidden, .payload_too_large => |err| {
                logError("Sending the invocation response failed: {s}.\n{s}", .{ err.type, err.message });
            },
        }
    }

    pub fn streamSuccess(self: *Server, content_type: []const u8) !Stream {
        const request = api.streamInvocationOpen(
            self.arena.allocator(),
            &self.http,
            self.context.request_id,
            content_type,
        ) catch |err| {
            return logErrorName("Opening a stream failed: {s}", err);
        };

        return .{
            .req = request,
            .arena = self.arena.allocator(),
        };
    }

    pub const Stream = struct {
        req: HttpClient.Request,
        arena: std.mem.Allocator,

        pub fn write(self: *Stream, payload: []const u8) !void {
            const writer = self.req.writer();
            writer.writeAll(payload) catch |err| {
                return logErrorName("Writing to the stream’s buffer failed: {s}", err);
            };
        }

        pub fn writeFmt(self: *Stream, comptime format: []const u8, args: anytype) !void {
            const writer = self.req.writer();
            writer.print(format, args) catch |err| {
                return logErrorName("Writing to the stream’s buffer failed: {s}", err);
            };
        }

        pub fn flush(self: *Stream) !void {
            const conn = self.req.connection.?;
            conn.flush() catch |err| {
                return logErrorName("Flushing the stream’s buffer failed: {s}", err);
            };
        }

        pub fn close(self: *Stream, err: ?api.ErrorRequest) !void {
            const result = api.streamInvocationClose(&self.req, self.arena, err) catch |e| {
                return logErrorName("Closing the stream failed: {s}", e);
            };

            switch (result) {
                .accepted => {},
                .bad_request, .forbidden, .payload_too_large => |e| {
                    logError("Closing the stream failed: {s}.\n{s}", .{ e.type, e.message });
                },
            }
        }
    };
};

fn logError(comptime format: []const u8, args: anytype) void {
    lambda.log_runtime.err(format, args);
}

fn logErrorName(comptime format: []const u8, err: anyerror) anyerror {
    lambda.log_runtime.err(format, .{@errorName(err)});
    return err;
}
