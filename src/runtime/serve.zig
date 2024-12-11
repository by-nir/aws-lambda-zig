const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const ctx = @import("context.zig");
const HttpClient = @import("../utils/Http.zig");
const environ = @import("../utils/environ.zig");
const log = @import("../utils/log.zig").runtime;

pub const ProcessorFn = *const fn (server: *Server, ctx: ctx.Context, event: []const u8) InvocationResult;

pub const InvocationResult = enum {
    /// The runtime may process another event.
    success,
    /// The runtime should terminate the lambda instance.
    abort,
};

pub const Options = struct {};

pub const Server = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    arena: std.heap.ArenaAllocator,
    http: HttpClient,
    env: std.process.EnvMap,
    request_id: []const u8 = "",

    pub fn init(self: *Server, _: Options) !void {
        errdefer self.* = undefined;

        self.gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const gpa_alloc = self.gpa.allocator();
        errdefer _ = self.gpa.deinit();

        const child_alloc = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
        self.arena = std.heap.ArenaAllocator.init(child_alloc);
        const arena_alloc = self.arena.allocator();
        errdefer self.arena.deinit();

        environ.load(&self.env, gpa_alloc) catch |err| {
            return initFailed(arena_alloc, null, err, "Loading the environment variables failed");
        };
        errdefer self.env.deinit();

        const api_origin = blk: {
            const origin = self.env.get(api.ENV_ORIGIN);
            if (origin) |o| if (o.len > 0) break :blk o;

            return initFailed(arena_alloc, null, error.MissingRuntimeOrigin, "Missing the runtime’s API origin URL");
        };

        self.http = HttpClient.init(gpa_alloc, api_origin) catch |err| {
            return initFailed(arena_alloc, null, err, "Creating a HTTP client failed");
        };
    }

    pub fn deinit(self: *Server) void {
        self.http.deinit();
        self.env.deinit();
        self.arena.deinit();

        switch (self.gpa.deinit()) {
            .ok => {},
            .leak => {
                // In debug mode we warn about leaks when the function instance terminates.
                log.warn("The GPA allocator detected a leak when terminating the instance.", .{});
            },
        }
    }

    fn initFailed(arena: Allocator, http: ?*HttpClient, err: anyerror, message: []const u8) anyerror {
        log.err("[Init] {s}: {s}", .{ message, @errorName(err) });
        const h2p = http orelse return err;

        const request = api.ErrorRequest{
            .type = err,
            .message = message,
        };

        const result = api.sendInitFail(arena, h2p, request) catch |e| {
            log.err("Sending the initialization’s error report failed: {s}", .{@errorName(e)});
            return err; // Intentional `err` instead of `e`
        };

        switch (result) {
            .accepted => {},
            .forbidden => |e| {
                log.err("Sending the initialization’s error report failed: {s}.\n{s}", .{ e.type, e.message });
            },
        }

        return err;
    }

    /// Event loop – request and invocate events sequentially.
    pub fn listen(self: *Server, processorFn: ProcessorFn) void {
        var force_terminate = false;
        var context = ctx.Context{
            .gpa = self.gpa.allocator(),
            .arena = self.arena.allocator(),
            ._force_destroy = &force_terminate,
        };
        ctx.loadMeta(&context, &self.env);

        // Request the next event
        while (api.sendInvocationNext(self.arena.allocator(), &self.http)) |next| {
            // Handle the event
            switch (next) {
                // Failed retrieving the event
                .forbidden => |err| {
                    log.err("Requesting the next invocation failed: {s}.\n{s}", .{ err.type, err.message });
                },

                // Update event-specific metadata
                .success => |event| {
                    self.request_id = event.request_id;
                    ctx.updateMeta(&context, event);

                    // Process the event
                    const status = processorFn(self, context, event.payload);
                    if (status == .abort) {
                        // The handler failed processing the event
                        return;
                    } else if (force_terminate) {
                        @panic("The handler requested to terminate the instance");
                    }
                },
            }

            // Clean-up ahead of the next invocation
            _ = self.arena.reset(.retain_capacity);
        } else |err| {
            log.err("Requesting the next invocation failed: {s}", .{@errorName(err)});
        }
    }

    pub fn respondFailure(self: *Server, err: anyerror, trace: ?*std.builtin.StackTrace) !void {
        if (trace) |t| {
            log.err("The handler returned an error `{s}`.{?}", .{ @errorName(err), t });
        } else {
            log.err("The handler returned an error `{s}`.", .{@errorName(err)});
        }

        const request = api.ErrorRequest{
            .type = err,
            .message = "The handler returned an error response.",
        };

        const alloc = self.arena.allocator();
        const result = api.sendInvocationFail(alloc, &self.http, self.request_id, request) catch |e| {
            return logErrorName("Sending the invocation’s error report failed: {s}", e);
        };

        switch (result) {
            .accepted => {},
            .bad_request, .forbidden => |e| {
                log.err("Sending the invocation’s error report failed: {s}.\n{s}", .{ e.type, e.message });
            },
        }
    }

    pub fn respondSuccess(self: *Server, output: []const u8) !void {
        const alloc = self.arena.allocator();
        const result = api.sendInvocationSuccess(alloc, &self.http, self.request_id, output) catch |err| {
            return logErrorName("Sending the invocation’s output failed: {s}", err);
        };

        switch (result) {
            .accepted => {},
            .bad_request, .forbidden, .payload_too_large => |err| {
                log.err("Sending the invocation response failed: {s}.\n{s}", .{ err.type, err.message });
            },
        }
    }

    pub fn streamSuccess(
        self: *Server,
        content_type: []const u8,
        comptime raw_http_prelude: []const u8,
        args: anytype,
    ) !Stream {
        const alloc = self.arena.allocator();
        const request = api.streamInvocationOpen(
            alloc,
            &self.http,
            self.request_id,
            content_type,
            raw_http_prelude,
            args,
        ) catch |err| {
            return logErrorName("Opening a stream failed: {s}", err);
        };

        return .{
            .req = request,
            .arena = alloc,
        };
    }

    pub const Stream = struct {
        req: HttpClient.Request,
        arena: std.mem.Allocator,

        pub const Writer = std.http.Client.Request.Writer;

        pub fn writer(self: *Stream) Writer {
            return self.req.writer();
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
                    log.err("Closing the stream failed: {s}.\n{s}", .{ e.type, e.message });
                },
            }
        }
    };
};

fn logErrorName(comptime format: []const u8, err: anyerror) anyerror {
    log.err(format, .{@errorName(err)});
    return err;
}
