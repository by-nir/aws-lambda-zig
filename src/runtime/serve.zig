const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const ctx = @import("context.zig");
const HttpClient = @import("../utils/Http.zig");
const environ = @import("../utils/environ.zig");
const log = @import("../utils/log.zig").runtime;

pub const Options = struct {};

pub const ProcessorFn = *const fn (
    server: *Server,
    context: ctx.Context,
    event: []const u8,
) InvocationResult;

pub const InvocationResult = enum {
    /// The runtime may process another event.
    success,
    /// The runtime should terminate the lambda instance.
    abort,
};

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
        _ = self.gpa.deinit();
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
        var context = ctx.Context{
            .gpa = self.gpa.allocator(),
            .arena = self.arena.allocator(),
        };
        ctx.loadMeta(&context, &self.env);

        while (true) {
            // Request the next event
            const next = api.sendInvocationNext(self.arena.allocator(), &self.http) catch |err| {
                log.err("Requesting the next invocation failed: {s}", .{@errorName(err)});
                return;
            };

            // Handle the event
            switch (next) {
                .forbidden => |err| {
                    // Failed retrieving the event
                    log.err("Requesting the next invocation failed: {s}.\n{s}", .{ err.type, err.message });
                },
                .success => |event| {
                    // Update event-specific metadata
                    self.request_id = event.request_id;
                    ctx.updateMeta(&context, event);
                    defer context.request.xray_trace = "";

                    // Process the event
                    if (processorFn(self, context, event.payload) == .abort) return;
                },
            }

            // Clean-up ahead of the next invocation
            _ = self.arena.reset(.retain_capacity);
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

    pub fn streamSuccess(self: *Server, content_type: []const u8) !Stream {
        const alloc = self.arena.allocator();
        const request = api.streamInvocationOpen(alloc, &self.http, self.request_id, content_type) catch |err| {
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
