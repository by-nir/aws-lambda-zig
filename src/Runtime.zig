const std = @import("std");
const Allocator = std.mem.Allocator;
const lambda = @import("lambda.zig");
const Client = @import("Client.zig");
const api = @import("api_runtime.zig");

const Self = @This();

/// Return `true` when the runtime can process another event, `false` when it should terminate.
pub const processorFn = *const fn (runtime: *Self, payload: []const u8) bool;

allocs: lambda.Allocators,
context: lambda.Context,
client: Client,

pub fn init(allocs: lambda.Allocators) !Self {
    var context = lambda.Context.init(allocs.gpa) catch |e| {
        initFailed(allocs.arena, null, e, "Creating the runtime context failed");
        return e;
    };
    errdefer context.deinit(allocs.gpa);

    const client = Client.init(allocs.gpa, context.api_origin) catch |e| {
        initFailed(allocs.arena, null, e, "Creating a client failed");
        return e;
    };

    return .{
        .allocs = allocs,
        .context = context,
        .client = client,
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.context.deinit(self.allocs.gpa);
}

fn initFailed(arena: Allocator, client: ?*Client, err: anyerror, message: []const u8) void {
    lambda.log_runtime.err("[Init] {s}: {s}", .{ message, @errorName(err) });
    if (client) |c| {
        const result = api.sendInitFail(arena, c, .{
            .typing = err,
            .message = message,
        }) catch |e| {
            lambda.log_runtime.err(
                "[Init Failed] Sending the initialization’s error report failed: {s}",
                .{@errorName(e)},
            );
            return;
        };
        switch (result) {
            .accepted => {},
            .forbidden => |e| {
                lambda.log_runtime.err(
                    "[Init Failed] Sending the initialization’s error report failed: {s}.\n{s}",
                    .{ e.error_type, e.message },
                );
            },
        }
    }
}

/// Request and invocate events sequentially.
pub fn eventLoop(self: *Self, arena: *std.heap.ArenaAllocator, processor: processorFn) void {
    while (true) {
        // Request the next event
        const next = api.sendInvocationNext(self.allocs.arena, &self.client) catch |e| {
            lambda.log_runtime.err(
                "[Event Loop] Requesting the next invocation failed: {s}",
                .{@errorName(e)},
            );
            return;
        };
        // Handle the event
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

                if (!processor(self, event.payload)) {
                    return;
                }
            },
        }

        // Clean-up ahed of the next invocation
        _ = arena.reset(.retain_capacity);
    }
}

pub fn respondFailure(self: *Self, err: anyerror, trace: ?*std.builtin.StackTrace) !void {
    const log = "[Event Loop] The handler returned an error `{s}`.";
    if (trace) |t| {
        lambda.log_runtime.err(log ++ "{?}", .{ @errorName(err), t });
    } else {
        lambda.log_runtime.err(log, .{@errorName(err)});
    }

    const result = api.sendInvocationFail(self.allocs.arena, &self.client, self.context.request_id, .{
        .typing = err,
        .message = "The handler returned an error response.",
    }) catch |e| {
        lambda.log_runtime.err(
            "[Respond Failure] Sending the invocation’s error report failed: {s}",
            .{@errorName(e)},
        );
        return e;
    };
    switch (result) {
        .accepted => {},
        .bad_request, .forbidden => |e| {
            lambda.log_runtime.err(
                "[Respond Failure] Sending the invocation’s error report failed: {s}.\n{s}",
                .{ e.error_type, e.message },
            );
        },
    }
}

pub fn respondSuccess(self: *Self, output: []const u8) !void {
    const result = api.sendInvocationSuccess(self.allocs.arena, &self.client, self.context.request_id, output) catch |e| {
        lambda.log_runtime.err(
            "[Respond Success] Sending the invocation’s output failed: {s}",
            .{@errorName(e)},
        );
        return e;
    };
    switch (result) {
        .accepted => {},
        .bad_request, .forbidden, .payload_too_large => |e| {
            lambda.log_runtime.err(
                "[Respond Success] Sending the invocation’s response failed: {s}.\n{s}",
                .{ e.error_type, e.message },
            );
        },
    }
}

pub fn streamSuccess(self: *Self, content_type: []const u8) !Stream {
    const request = api.streamInvocationOpen(self.allocs.arena, &self.client, self.context.request_id, content_type) catch |e| {
        lambda.log_runtime.err(
            "[Stream Success] Opening the invocation’s stream failed: {s}",
            .{@errorName(e)},
        );
        return e;
    };
    return Stream{
        .req = request,
        .arena = self.allocs.arena,
    };
}

pub const Stream = struct {
    req: Client.Request,
    arena: std.mem.Allocator,

    pub fn append(self: *Stream, payload: []const u8) !void {
        api.streamInvocationAppend(&self.req, payload) catch |e| {
            lambda.log_runtime.err(
                "[Stream Success] Appending to the invocation’s stream failed: {s}",
                .{@errorName(e)},
            );
            return e;
        };
    }

    pub fn close(self: *Stream, err: ?api.ErrorRequest) !void {
        const result = api.streamInvocationClose(&self.req, self.arena, err) catch |e| {
            lambda.log_runtime.err(
                "[Stream Success] Closing the invocation’s stream failed: {s}",
                .{@errorName(e)},
            );
            return e;
        };
        switch (result) {
            .accepted => {},
            .bad_request, .forbidden, .payload_too_large => |e| {
                lambda.log_runtime.err(
                    "[Stream Success] Closing the invocation’s stream failed: {s}.\n{s}",
                    .{ e.error_type, e.message },
                );
            },
        }
    }
};
