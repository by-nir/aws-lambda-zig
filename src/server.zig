const std = @import("std");
const lambda = @import("lambda.zig");
const Client = @import("Client.zig");
const Runtime = @import("Runtime.zig");

const handlerFn = *const fn (
    allocs: lambda.Allocators,
    context: *const lambda.Context,
    /// The event’s JSON payload
    event: []const u8,
) anyerror![]const u8;


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

pub fn serveBuffer(comptime handler: handlerFn) void {
    const Invocation = struct {
        fn process(rt: *Runtime, payload: []const u8) bool {
            if (handler(rt.allocs, &rt.context, payload)) |output| {
                rt.respondSuccess(output) catch return false;
            } else |e| {
                rt.respondFailure(e, @errorReturnTrace()) catch return false;
            }
            return true;
        }
    };

    serve(Invocation.process);
}
