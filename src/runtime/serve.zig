const std = @import("std");
const api = @import("api.zig");
const ctx = @import("context.zig");
const HttpClient = @import("../utils/Http.zig");
const log = @import("../utils/log.zig").runtime;

pub const ProcessorFn =
    *const fn (server: *Server, ctx: ctx.Context, event: []const u8) InvocationResult;

pub const InvocationResult = enum {
    /// The runtime may process another event.
    success,
    /// The runtime should terminate the lambda instance.
    abort,
};

pub const Options = struct {};

pub const Server = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    http: HttpClient,
    env: *const std.process.Environ.Map,
    request_id: []const u8 = "",

    pub fn init(self: *@This(), proc_init: std.process.Init, _: Options) !void {
        errdefer self.* = undefined;

        self.gpa = proc_init.gpa;
        self.env = proc_init.environ_map;

        self.arena = blk: {
            const child_alloc =
                if (@import("builtin").is_test)
                    std.testing.allocator
                else
                    std.heap.page_allocator;

            break :blk .init(child_alloc);
        };
        errdefer self.arena.deinit();

        const api_origin = blk: {
            const origin = self.env.get(api.ENV_ORIGIN);
            if (origin) |o| if (o.len > 0) break :blk o;

            return initFailed(
                self.arena.allocator(),
                null,
                error.MissingRuntimeOrigin,
                "Missing the runtime’s API origin URL",
            );
        };

        // Initialize threaded IO - owned by Server
        self.threaded = std.Io.Threaded.init(self.gpa, .{
            .environ = proc_init.minimal.environ,
        });
        errdefer self.threaded.deinit();

        self.io = self.threaded.io();

        HttpClient.init(&self.http, self.gpa, api_origin, self.io) catch |err| {
            return initFailed(self.arena.allocator(), null, err, "Creating a HTTP client failed");
        };
    }

    pub fn deinit(self: *@This()) void {
        self.http.deinit();
        self.arena.deinit();
        self.threaded.deinit();
    }

    fn initFailed(
        arena: std.mem.Allocator,
        http: ?*HttpClient,
        err: anyerror,
        message: []const u8,
    ) anyerror {
        log.err("[Init] {s}: {s}", .{ message, @errorName(err) });
        const h2p = http orelse return err;

        const request = api.ErrorRequest{
            .type = err,
            .message = message,
        };

        const result = api.sendInitFail(arena, h2p, request) catch |e| {
            log.err(
                "Sending the initialization’s error report failed: {s}",
                .{@errorName(e)},
            );

            // Intentional return `err` instead of `e`.
            return err;
        };

        switch (result) {
            .accepted => {},
            .forbidden => |e| {
                log.err(
                    "Sending the initialization’s error report failed: {s}.\n{s}",
                    .{ e.type, e.message },
                );
            },
        }

        return err;
    }

    /// Event loop – request and invocate events sequentially.
    pub fn listen(self: *@This(), processorFn: ProcessorFn) void {
        var force_terminate = false;
        var context: ctx.Context = .{
            .io = self.io,
            .gpa = self.gpa,
            .arena = self.arena.allocator(),
            .__client__ = &self.http,
            .__force_destroy__ = &force_terminate,
        };
        ctx.loadMeta(&context, self.env);

        // Request the next event
        while (api.sendInvocationNext(self.arena.allocator(), &self.http)) |next| {
            // Handle the event
            switch (next) {
                // Failed retrieving the event
                .forbidden => |err| {
                    log.err(
                        "Requesting the next invocation failed: {s}.\n{s}",
                        .{ err.type, err.message },
                    );
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

    pub fn respondFailure(self: *@This(), err: anyerror, trace: ?*std.builtin.StackTrace) !void {
        log.err("The handler returned an error `{s}`.", .{@errorName(err)});

        if (trace) |st| {
            var buffer: [64]u8 = undefined;
            const stderr = std.debug.lockStderr(&buffer).terminal();
            defer std.debug.unlockStderr();

            try std.debug.writeErrorReturnTrace(st, stderr);
        }

        const request = api.ErrorRequest{
            .type = err,
            .message = "The handler returned an error response.",
        };

        const alloc = self.arena.allocator();
        const result =
            api.sendInvocationFail(alloc, &self.http, self.request_id, request) catch |e| {
                return logErrorName("Sending the invocation’s error report failed: {s}", e);
            };

        switch (result) {
            .accepted => {},
            .bad_request, .forbidden => |e| {
                log.err(
                    "Sending the invocation’s error report failed: {s}.\n{s}",
                    .{ e.type, e.message },
                );
            },
        }
    }

    pub fn respondSuccess(self: *@This(), output: []const u8) !void {
        const arena = self.arena.allocator();
        const result =
            api.sendInvocationSuccess(arena, &self.http, self.request_id, output) catch |err| {
                return logErrorName("Sending the invocation’s output failed: {s}", err);
            };

        switch (result) {
            .accepted => {},
            .bad_request, .forbidden, .payload_too_large => |err| {
                log.err(
                    "Sending the invocation response failed: {s}.\n{s}",
                    .{ err.type, err.message },
                );
            },
        }
    }

    pub fn streamSuccess(
        self: *@This(),
        content_type: []const u8,
        comptime prelude_raw_http: []const u8,
        prelude_args: anytype,
    ) !Stream {
        const arena = self.arena.allocator();
        const request, const body =
            api.streamInvocationOpen(
                arena,
                &self.http,
                self.request_id,
                content_type,
                prelude_raw_http,
                prelude_args,
            ) catch |err| {
                return logErrorName("Opening a stream failed: {s}", err);
            };

        return .{
            .arena = arena,
            .req = request,
            .body = body,
        };
    }

    pub const Stream = struct {
        req: HttpClient.Request,
        body: std.http.BodyWriter,
        arena: std.mem.Allocator,

        pub fn writer(self: *Stream) *std.Io.Writer {
            return &self.body.writer;
        }

        pub fn flush(self: *Stream) !void {
            self.body.flush() catch |err| {
                return logErrorName("Flushing the stream’s buffer failed: {s}", err);
            };
        }

        pub fn close(self: *Stream, err: ?api.ErrorRequest) !void {
            const result =
                api.streamInvocationClose(self.arena, &self.req, &self.body, err) catch |e| {
                    return logErrorName("Closing the stream failed: {s}", e);
                };

            switch (result) {
                .accepted => {},
                .bad_request, .forbidden, .payload_too_large => |e| {
                    log.err(
                        "Closing the stream failed: {s}.\n{s}",
                        .{ e.type, e.message },
                    );
                },
            }
        }
    };
};

fn logErrorName(comptime format: []const u8, err: anyerror) anyerror {
    log.err(format, .{@errorName(err)});
    return err;
}
