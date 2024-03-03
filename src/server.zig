const std = @import("std");
const lambda = @import("lambda.zig");
const Client = @import("Client.zig");
const Runtime = @import("Runtime.zig");
const Channel = @import("Channel.zig");

const handlerFn = *const fn (
    allocs: lambda.Allocators,
    context: *const lambda.Context,
    /// The event’s JSON payload
    event: []const u8,
) anyerror![]const u8;

const handlerStreamFn = *const fn (
    allocs: lambda.Allocators,
    context: *const lambda.Context,
    /// The event’s JSON payload
    event: []const u8,
    stream: Channel,
) anyerror!void;

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

pub fn serveStream(comptime handler: handlerStreamFn) void {
    const Invocation = struct {
        const Self = @This();
        const State = enum { pending, active, end };

        var state: State = .pending;
        var stream: Runtime.Stream = undefined;
        var runtime_error: bool = false;

        fn process(rt: *Runtime, payload: []const u8) bool {
            state = .pending;
            stream = undefined;
            runtime_error = false;

            const channel = Channel{
                .ctx = rt,
                .vtable = &ChannelVT,
            };

            const allocs = rt.allocs;
            handler(allocs, &rt.context, payload, channel) catch |e| {
                if (state == .pending) {
                    rt.respondFailure(e, @errorReturnTrace()) catch return false;
                    return !runtime_error;
                }

                lambda.log_runtime.err(
                    "[Processor] The handler returned an error after opening a stream: {s}",
                    .{@errorName(e)},
                );
            };

            switch (state) {
                .pending => rt.respondFailure(error.NoResponse, null) catch return false,
                .active => stream.close(null) catch return false,
                .end => {},
            }
            return !runtime_error;
        }

        const ChannelVT = Channel.VTable{
            .open = open,
            .write = write,
            .close = close,
            .fail = fail,
        };

        fn getRuntime(ctx: *anyopaque) *Runtime {
            return @alignCast(@ptrCast(ctx));
        }

        fn open(ctx: *anyopaque, content_type: []const u8) Channel.Error!void {
            if (state != .pending or runtime_error) return;
            std.debug.assert(content_type.len > 0);
            const rt = getRuntime(ctx);
            stream = rt.streamSuccess(content_type) catch {
                runtime_error = true;
                return error.RuntimeFail;
            };
            state = .active;
        }

        fn write(_: *anyopaque, payload: []const u8) Channel.Error!void {
            if (state != .active or runtime_error) return error.NotOpen;
            stream.append(payload) catch {
                runtime_error = true;
                return error.RuntimeFail;
            };
        }

        fn close(_: *anyopaque) Channel.Error!void {
            if (state != .active or runtime_error) return error.NotOpen;
            state = .end;
            stream.close(null) catch {
                runtime_error = true;
                return error.RuntimeFail;
            };
        }

        fn fail(_: *anyopaque, err: anyerror, message: []const u8) Channel.Error!void {
            if (state != .active or runtime_error) return error.NotOpen;
            state = .end;
            stream.close(.{ .typing = err, .message = message }) catch {
                runtime_error = true;
                return error.RuntimeFail;
            };
        }
    };

    serve(Invocation.process);
}
