const std = @import("std");
const lambda = @import("lambda.zig");
const Fetcher = @import("Fetcher.zig");
const api = @import("api_runtime.zig");

const Self = @This();

pub const processorFn = *const fn (
    allocs: lambda.Allocators,
    runtime: *Self,
    payload: []const u8,
) bool;

allocs: lambda.Allocators,
fetcher: Fetcher,
context: lambda.Context,
next_url: []const u8,

pub fn init(allocs: lambda.Allocators) !Self {
    var fetcher = Fetcher.init(allocs.gpa, allocs.arena);
    errdefer fetcher.deinit();

    var context = lambda.Context.init(allocs.gpa) catch |e| {
        initFailed(allocs.gpa, null, undefined, e, "Loading the environment context failed");
        return e;
    };
    errdefer context.deinit(allocs.gpa);

    const next_url = api.urlInvocationNext(allocs.gpa, context.api_host) catch |e| {
        initFailed(allocs.gpa, context.api_host, &fetcher, e, "Interperting next invocation’s url failed");
        return e;
    };

    return Self{
        .allocs = allocs,
        .fetcher = fetcher,
        .context = context,
        .next_url = next_url,
    };
}

pub fn deinit(self: *Self) void {
    self.allocs.gpa.free(self.next_url);
    self.context.deinit(self.allocs.gpa);
    self.fetcher.deinit();
}

/// Request and invocate events sequentially.
pub fn eventLoop(self: *Self, arena: *std.heap.ArenaAllocator, processor: processorFn) void {
    while (true) {
        // Request the next event
        const next = api.sendInvocationNext(self.allocs.arena, &self.fetcher, self.next_url) catch |e| {
            lambda.log_runtime.err(
                "[Event Loop] Requesting the next invocation failed: {s}",
                .{@errorName(e)},
            );
            return;
        };

        switch (next) {
            // Failed retrieving the event
            .forbidden => |e| {
                lambda.log_runtime.err(
                    "[Event Loop] Requesting the next invocation failed: {s}.\n{s}",
                    .{ e.error_type, e.message },
                );
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

                if (!processor(self.allocs, self, event.payload)) {
                    return;
                }
            },
        }

        // Clean-up ahed of the next invocation.
        _ = arena.reset(.retain_capacity);
    }
}

fn initFailed(
    gpa: std.mem.Allocator,
    host: ?[]const u8,
    fetcher: *Fetcher,
    init_error: anyerror,
    message: []const u8,
) void {
    @setCold(true);
    lambda.log_runtime.err("[Main] {s}: {s}", .{ message, @errorName(init_error) });

    const h = if (host) |h| h else return;
    const url = api.urlInitFail(gpa, h) catch |e| {
        return lambda.log_runtime.err(
            "[Init Failure] Interperting url failed: {s}",
            .{@errorName(e)},
        );
    };

    const error_type = std.fmt.allocPrint(gpa, "Runtime.{s}", .{@errorName(init_error)}) catch |e| {
        return lambda.log_runtime.err(
            "[Init Failure] Composing error type failed: {s}",
            .{@errorName(e)},
        );
    };

    const err_req = api.ErrorRequest{
        .error_type = @errorName(init_error),
        .message = "Runtime initialization failed.",
    };
    const result = api.sendInitFail(gpa, fetcher, url, error_type, err_req) catch |e| {
        lambda.log_runtime.err(
            "[Init Failure] Sending the initialization’s error report failed: {s}",
            .{@errorName(e)},
        );
        return;
    };

    switch (result) {
        .accepted => {},
        .forbidden => |e| {
            lambda.log_runtime.err(
                "[Init Failure] Sending the initialization’s error report failed: {s}.\n{s}",
                .{ e.error_type, e.message },
            );
        },
    }
}
