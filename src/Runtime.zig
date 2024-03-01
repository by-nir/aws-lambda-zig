const std = @import("std");
const lambda = @import("lambda.zig");
const Fetcher = @import("Fetcher.zig");
const api = @import("api_runtime.zig");

const Self = @This();

const FMT_ERROR = "[{s}] Interpreting URL failed: {s}";
pub const processorFn = *const fn (runtime: *Self, payload: []const u8) bool;

allocs: lambda.Allocators,
fetcher: Fetcher,
context: lambda.Context,
next_url: []const u8,

pub fn init(allocs: lambda.Allocators) !Self {
    var fetcher = Fetcher.init(allocs.gpa, allocs.arena);
    errdefer fetcher.deinit();

    var context = lambda.Context.init(allocs.gpa) catch |e| {
        initFailed(allocs.gpa, null, undefined, e, "Creating the runtime context failed");
        return e;
    };
    errdefer context.deinit(allocs.gpa);

    const next_url = std.fmt.allocPrint(
        allocs.gpa,
        api.URL_INVOC_NEXT,
        .{context.api_host},
    ) catch |e| {
        lambda.log_runtime.err(FMT_ERROR, .{ "Init Next", @errorName(e) });
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

fn initFailed(gpa: std.mem.Allocator, host: ?[]const u8, fetcher: *Fetcher, err: anyerror, message: []const u8) void {
    lambda.log_runtime.err("[Init] {s}: {s}", .{ message, @errorName(err) });

    const h = host orelse return;
    const url = std.fmt.allocPrint(gpa, api.URL_INIT_FAIL, .{h}) catch |e| {
        lambda.log_runtime.err(FMT_ERROR, .{ "Init Failed", @errorName(e) });
        return;
    };

    const result = api.sendInitFail(gpa, fetcher, url, err, message, null) catch |e| {
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

                if (!processor(self, event.payload)) {
                    return;
                }
            },
        }

        // Clean-up ahed of the next invocation.
        _ = arena.reset(.retain_capacity);
    }
}

pub fn respondSuccess(self: *Self, output: []const u8) !void {
    const url = std.fmt.allocPrint(
        self.allocs.arena,
        api.URL_INVOC_SUCCESS,
        .{ self.context.api_host, self.context.request_id },
    ) catch |e| {
        lambda.log_runtime.err(FMT_ERROR, .{ "Invocation Success", @errorName(e) });
        return e;
    };

    const result = api.sendInvocationSuccess(self.allocs.arena, &self.fetcher, url, output) catch |e| {
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

pub fn respondFailure(self: *Self, err: anyerror, trace: ?*std.builtin.StackTrace) !void {
    const log = "[Event Loop] The handler returned an error `{s}`.";
    if (trace) |t| {
        lambda.log_runtime.err(log ++ "{?}", .{ @errorName(err), t });
    } else {
        lambda.log_runtime.err(log, .{@errorName(err)});
    }

    const url = std.fmt.allocPrint(
        self.allocs.arena,
        api.URL_INVOC_FAIL,
        .{ self.context.api_host, self.context.request_id },
    ) catch |e| {
        lambda.log_runtime.err(FMT_ERROR, .{ "Invocation Fail", @errorName(e) });
        return e;
    };

    const result = api.sendInvocationFail(self.allocs.arena, &self.fetcher, url, err, "The handler returned an error response.", null) catch |e| {
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
