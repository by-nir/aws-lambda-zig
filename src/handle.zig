const std = @import("std");
const lambda = @import("lambda.zig");
const Fetcher = @import("Fetcher.zig");
const api = @import("api_runtime.zig");

pub const Allocators = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
};

const handlerFn = *const fn (
    allocs: Allocators,
    context: *const lambda.Context,
    /// The event’s JSON payload
    event: []const u8,
) anyerror![]const u8;

pub fn run(handler: handlerFn) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocs = Allocators{
        .gpa = gpa.allocator(),
        .arena = arena.allocator(),
    };

    var fetcher = Fetcher.init(allocs.gpa, allocs.arena);
    defer fetcher.deinit();

    var env = lambda.getEnvVars(allocs.gpa) catch |e| {
        return initFail(allocs.gpa, null, undefined, e, "Loading environment variables failed");
    };
    defer env.deinit();

    var context = lambda.Context.from(&env) catch |e| {
        return initFail(allocs.gpa, null, undefined, e, "Environment missing the Runtime API’s host");
    };

    const next_url = api.urlInvocationNext(allocs.gpa, context.api_host) catch |e| {
        return initFail(allocs.gpa, context.api_host, &fetcher, e, "Interperting next invocation’s url failed");
    };
    defer allocs.gpa.free(next_url);

    // Run the event loop until an error occurs or the process is terminated.
    while (eventInvocation(allocs, &fetcher, &context, next_url, handler)) {
        // Clean-up ahed of the next invocation.
        _ = arena.reset(.retain_capacity);
    }
}

fn eventInvocation(
    allocs: Allocators,
    fetcher: *Fetcher,
    ctx: *lambda.Context,
    next_url: []const u8,
    handler: handlerFn,
) bool {
    // Request the next event
    const next = api.sendInvocationNext(allocs.arena, fetcher, next_url) catch |e| {
        lambda.log_runtime.err(
            "[Event Loop] Requesting the next invocation failed: {s}",
            .{@errorName(e)},
        );
        return false;
    };

    switch (next) {
        // Failed retrieving the event
        .forbidden => |e| {
            lambda.log_runtime.err(
                "[Event Loop] Requesting the next invocation failed: {s}.\n{s}",
                .{ e.error_type, e.message },
            );
            return true;
        },

        // Process the event
        .success => |event| {
            // Set up the event’s context
            ctx.request_id = event.request_id;
            ctx.invoked_arn = event.invoked_arn;
            ctx.deadline_ms = event.deadline_ms;
            ctx.client_context = event.client_context;
            ctx.cognito_identity = event.cognito_identity;
            ctx.xray_trace = event.xray_trace;
            defer ctx.xray_trace = &[_]u8{};

            if (handler(allocs, ctx, event.payload)) |output| {
                return handlerSuccess(allocs.arena, ctx.api_host, ctx.request_id, fetcher, output);
            } else |e| {
                return handlerFail(allocs.arena, ctx.api_host, ctx.request_id, fetcher, e, @errorReturnTrace());
            }
        },
    }
}

fn handlerSuccess(
    arena: std.mem.Allocator,
    api_host: []const u8,
    request_id: []const u8,
    fetcher: *Fetcher,
    output: []const u8,
) bool {
    const url = api.urlInvocationSuccess(arena, api_host, request_id) catch |e| {
        lambda.log_runtime.err(
            "[Handler Success] Interperting url failed: {s}",
            .{@errorName(e)},
        );
        return false;
    };

    const result = api.sendInvocationSuccess(arena, fetcher, url, output) catch |e| {
        lambda.log_runtime.err(
            "[Handler Success] Sending the invocation’s output failed: {s}",
            .{@errorName(e)},
        );
        return false;
    };

    switch (result) {
        .accepted => {},
        .bad_request, .forbidden, .payload_too_large => |e| {
            lambda.log_runtime.err(
                "[Handler Success] Sending the invocation’s response failed: {s}.\n{s}",
                .{ e.error_type, e.message },
            );
        },
    }
    return true;
}

fn handlerFail(
    arena: std.mem.Allocator,
    api_host: []const u8,
    request_id: []const u8,
    fetcher: *Fetcher,
    handler_error: anyerror,
    trace: ?*std.builtin.StackTrace,
) bool {
    @setCold(true);
    const log = "[Event Loop] The handler returned an error `{s}`.";
    if (trace) |t| {
        lambda.log_runtime.err(log ++ "{?}", .{ @errorName(handler_error), t });
    } else {
        lambda.log_runtime.err(log, .{@errorName(handler_error)});
    }

    const url = api.urlInvocationFail(arena, api_host, request_id) catch |e| {
        lambda.log_runtime.err(
            "[Handler Failure] Interperting url failed: {s}",
            .{@errorName(e)},
        );
        return false;
    };

    const err_req = api.ErrorRequest{
        .error_type = @errorName(handler_error),
        .message = "The handler returned an error response.",
    };
    const result = api.sendInvocationFail(arena, fetcher, url, "Handler.ErrorResponse", err_req) catch |e| {
        lambda.log_runtime.err(
            "[Handler Failure] Sending the invocation’s error report failed: {s}",
            .{@errorName(e)},
        );
        return false;
    };

    switch (result) {
        .accepted => {},
        .bad_request, .forbidden => |e| {
            lambda.log_runtime.err(
                "[Handler Success] Sending the invocation’s error report failed: {s}.\n{s}",
                .{ e.error_type, e.message },
            );
        },
    }
    return true;
}

fn initFail(
    gpa: std.mem.Allocator,
    api_host: ?[]const u8,
    fetcher: *Fetcher,
    init_error: anyerror,
    message: []const u8,
) void {
    @setCold(true);
    lambda.log_runtime.err("[Main] {s}: {s}", .{ message, @errorName(init_error) });

    if (api_host) |host| {
        const url = api.urlInitFail(gpa, host) catch |e| {
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
}
