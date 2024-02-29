const std = @import("std");
const lambda = @import("lambda.zig");
const Fetcher = @import("Fetcher.zig");
const Runtime = @import("Runtime.zig");
const api = @import("api_runtime.zig");

pub fn runBuffer(comptime handler: lambda.handlerFn) void {
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
    const processor = bufferProcessor(handler);
    runtime.eventLoop(&arena, processor);
}

fn bufferProcessor(comptime handler: lambda.handlerFn) Runtime.processorFn {
    const Processor = struct {
        fn process(allocs: lambda.Allocators, runtime: *Runtime, payload: []const u8) bool {
            if (handler(allocs, &runtime.context, payload)) |output| {
                return success(allocs.arena, &runtime.context, &runtime.fetcher, output);
            } else |e| {
                return failure(allocs.arena, &runtime.context, &runtime.fetcher, e, @errorReturnTrace());
            }
        }

        fn success(arena: std.mem.Allocator, ctx: *const lambda.Context, fetcher: *Fetcher, output: []const u8) bool {
            const url = api.urlInvocationSuccess(arena, ctx.api_host, ctx.request_id) catch |e| {
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

        fn failure(
            arena: std.mem.Allocator,
            ctx: *const lambda.Context,
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

            const url = api.urlInvocationFail(arena, ctx.api_host, ctx.request_id) catch |e| {
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
    };

    return Processor.process;
}
