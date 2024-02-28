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
    context: lambda.Context,
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

    var env = lambda.ReservedEnv.load() catch |e| {
        lambda.log_runtime.err("[Main] Loading environment variables failed: {s}", .{@errorName(e)});
        return;
    };

    const next_url = api.urlInvocationNext(allocs.gpa, env.runtime_api) catch |e|
        return initFail(allocs.gpa, env.runtime_api, &fetcher, e, "Interperting next invocation’s url failed");
    defer allocs.gpa.free(next_url);

    // Run the event loop until an error occurs or the process is terminated.
    while (eventInvocation(allocs, &fetcher, &env, next_url, handler)) {
        // Clean-up ahed of the next invocation.
        _ = arena.reset(.retain_capacity);
    }
}

fn eventInvocation(
    allocs: Allocators,
    fetcher: *Fetcher,
    env: *lambda.ReservedEnv,
    next_url: []const u8,
    handler: handlerFn,
) bool {
    // Request the next event
    const next = api.sendInvocationNext(allocs.arena, fetcher, next_url) catch |e| {
        lambda.log_runtime.err("[Event Loop] Event-loop process failed: {s}", .{@errorName(e)});
        return false;
    };

    switch (next) {
        // Failed retrieving the event
        .forbidden => return false,

        // Process the event
        .success => |event| {
            // Set up the event’s context
            env.xray_trace = event.xray_trace;
            const request_id = event.request_id;
            const context = lambda.Context{
                .env_reserved = env,
                .invoked_arn = event.invoked_arn,
                .deadline_ms = event.deadline_ms,
            };

            return if (handler(allocs, context, event.payload)) |output|
                handlerSuccess(allocs.arena, env.runtime_api, request_id, fetcher, output)
            else |e|
                handlerFail(allocs.arena, env.runtime_api, request_id, fetcher, e);
        },
    }
}

fn handlerSuccess(arena: std.mem.Allocator, api_host: []const u8, request_id: []const u8, fetcher: *Fetcher, output: []const u8) bool {
    const url = api.urlInvocationSuccess(arena, api_host, request_id) catch |e| {
        lambda.log_runtime.err("[Handler Success] Interperting url failed: {s}", .{@errorName(e)});
        return false;
    };

    const result = api.sendInvocationSuccess(arena, fetcher, url, output) catch |e| {
        lambda.log_runtime.err("[Handler Success] Sending the invocation’s output failed: {s}", .{@errorName(e)});
        return false;
    };

    return switch (result) {
        .accepted => true,
        .bad_request, .forbidden, .payload_too_large => false,
    };
}

const FALLBACK_HANDLER_LOG = "[Event Loop] Handler returned error: {s}";
fn handlerFail(
    arena: std.mem.Allocator,
    api_host: []const u8,
    request_id: []const u8,
    fetcher: *Fetcher,
    handler_error: anyerror,
) bool {
    const url = api.urlInvocationFail(arena, api_host, request_id) catch |e| {
        lambda.log_runtime.err(FALLBACK_HANDLER_LOG, .{@errorName(handler_error)});
        lambda.log_runtime.err("[Handler Failure] Interperting url failed: {s}", .{@errorName(e)});
        return false;
    };

    const result = api.sendInvocationFail(arena, fetcher, url, "Handler.ErrorResponse", api.ErrorRequest{
        .error_type = @errorName(handler_error),
        .message = "The handler returned an error response.",
    }) catch |e| {
        lambda.log_runtime.err(FALLBACK_HANDLER_LOG, .{@errorName(handler_error)});
        lambda.log_runtime.err("[Handler Failure] Sending the invocation’s error report failed: {s}", .{@errorName(e)});
        return false;
    };

    return switch (result) {
        .accepted => true,
        .bad_request, .forbidden => false,
    };
}

const FALLBACK_INIT_LOG = "[Main] {s}: {s}";
fn initFail(
    allocator: std.mem.Allocator,
    api_host: []const u8,
    fetcher: *Fetcher,
    init_error: anyerror,
    message: []const u8,
) void {
    const url = api.urlInitFail(allocator, api_host) catch |e| {
        lambda.log_runtime.err(FALLBACK_INIT_LOG, .{ message, @errorName(init_error) });
        lambda.log_runtime.err("[Init Failure] Interperting url failed: {s}", .{@errorName(e)});
        return;
    };

    const error_type = std.fmt.allocPrint(allocator, "Runtime.{s}", .{@errorName(init_error)}) catch |e| {
        lambda.log_runtime.err(FALLBACK_INIT_LOG, .{ message, @errorName(init_error) });
        lambda.log_runtime.err("[Init Failure] Composing error type failed: {s}", .{@errorName(e)});
        return;
    };

    _ = api.sendInitFail(allocator, fetcher, url, error_type, api.ErrorRequest{
        .error_type = @errorName(init_error),
        .message = "Runtime initialization failed.",
    }) catch |e| {
        lambda.log_runtime.err(FALLBACK_INIT_LOG, .{ message, @errorName(init_error) });
        lambda.log_runtime.err("[Init Failure] Sending the initialization’s error report failed: {s}", .{@errorName(e)});
        return;
    };
}
