const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const lambda = @import("lambda.zig");

const ERROR_HEAD_TYPE = "Lambda-Runtime-Function-Error-Type";
const ERROR_CONTENT_TYPE = "application/vnd.aws.lambda.error+json";

const API_BASE = "/2018-06-01/runtime/";
const URL_INIT_FAIL: []const u8 = API_BASE ++ "init/error";
const URL_INVOC_NEXT: []const u8 = API_BASE ++ "invocation/next";
pub const URL_INVOC_SUCCESS: []const u8 = API_BASE ++ "invocation/{s}/response";
pub const URL_INVOC_FAIL: []const u8 = API_BASE ++ "invocation/{s}/error";

pub const Error = error{ ParseError, ClientError, ContainerError, UnknownStatus } || Allocator.Error;

pub const InitFailResult = union(enum) {
    accepted: StatusResponse,
    forbidden: ErrorResponse,
};

/// Non-recoverable initialization error. Runtime should exit after reporting
/// the error. Error will be served in response to the first invoke.
///
/// `error_type` expects format _"category.reason"_ (example: _"Runtime.ConfigInvalid"_).
pub fn sendInitFail(
    arena: Allocator,
    client: *Client,
    err: anyerror,
    message: []const u8,
    trace: ?ErrorTrace,
) Error!InitFailResult {
    const req = ErrorRequest.from(arena, "Runtime", err, message, trace);
    const fetch = try sendError(arena, client, URL_INIT_FAIL, @errorName(err), req);
    return switch (fetch.status) {
        .accepted => .{ .accepted = try StatusResponse.parse(arena, fetch.body) },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

pub const InvocationNextResult = union(enum) {
    success: InvocationEvent,
    forbidden: ErrorResponse,
};

/// This is an iterator-style blocking API call. Runtime makes this request when
/// it is ready to process a new invoke.
pub fn sendInvocationNext(arena: Allocator, client: *Client) Error!InvocationNextResult {
    var fetch = try sendRequest(arena, client, .GET, URL_INVOC_NEXT, .{});
    return switch (fetch.status) {
        .success => .{ .success = try InvocationEvent.parse(arena, &fetch.headers, fetch.body) },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

pub const InvocationEvent = struct {
    /// AWS request ID associated with the request.
    request_id: []const u8,

    /// X-Ray tracing id.
    xray_trace: []const u8,

    /// The function ARN requested.
    ///
    /// **This can be different in each invoke** that executes the same version.
    invoked_arn: []const u8,

    /// Function execution deadline counted in milliseconds since the _Unix epoch_.
    deadline_ms: u64,

    /// Information about the client application and device when invoked through the AWS Mobile SDK.
    client_context: []const u8 = &[_]u8{},

    /// Information about the Amazon Cognito identity provider when invoked through the AWS Mobile SDK.
    cognito_identity: []const u8 = &[_]u8{},

    /// JSON document specific to the invoking service’s event.
    payload: []const u8,

    pub fn parse(arena: Allocator, headers: *Client.HeaderIterator, payload: []const u8) !InvocationEvent {
        var event = InvocationEvent{
            .request_id = undefined,
            .xray_trace = undefined,
            .invoked_arn = undefined,
            .deadline_ms = undefined,
            .payload = payload,
        };

        while (headers.next()) |header| {
            if (std.mem.eql(u8, "Lambda-Runtime-Aws-Request-Id", header.name))
                event.request_id = try duplicate(arena, header.value)
            else if (std.mem.eql(u8, "Lambda-Runtime-Trace-Id", header.name))
                event.xray_trace = try duplicate(arena, header.value)
            else if (std.mem.eql(u8, "Lambda-Runtime-Invoked-Function-Arn", header.name))
                event.invoked_arn = try duplicate(arena, header.value)
            else if (std.mem.eql(u8, "Lambda-Runtime-Deadline-Ms", header.name))
                event.deadline_ms = std.fmt.parseInt(u64, header.value, 10) catch 0
            else if (std.mem.eql(u8, "Lambda-Runtime-Client-Context", header.name))
                event.client_context = try duplicate(arena, header.value)
            else if (std.mem.eql(u8, "Lambda-Runtime-Cognito-Identity", header.name))
                event.cognito_identity = try duplicate(arena, header.value);
        }

        return event;
    }

    /// Remaining time in **milliseconds** before the function execution aborts.
    pub fn remaining(self: InvocationEvent) u64 {
        return @as(u64, @intCast(std.time.milliTimestamp())) - self.deadline_timestamp;
    }

    fn duplicate(arena: Allocator, src: []const u8) ![]const u8 {
        const dest = try arena.alloc(u8, src.len);
        @memcpy(dest, src);
        return dest;
    }
};

pub const InvocationSuccessResult = union(enum) {
    accepted: StatusResponse,
    bad_request: ErrorResponse,
    forbidden: ErrorResponse,
    payload_too_large: ErrorResponse,
};

/// Runtime makes this request in order to submit a response.
pub fn sendInvocationSuccess(
    arena: Allocator,
    client: *Client,
    path: []const u8,
    payload: []const u8,
) Error!InvocationSuccessResult {
    const fetch = try sendRequest(arena, client, .POST, path, .{
        .payload = payload,
    });
    return switch (fetch.status) {
        .accepted => .{ .accepted = try StatusResponse.parse(arena, fetch.body) },
        .bad_request => .{ .bad_request = try ErrorResponse.parse(arena, fetch.body) },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, fetch.body) },
        .payload_too_large => .{ .payload_too_large = try ErrorResponse.parse(arena, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

pub const InvocationFailResult = union(enum) {
    accepted: StatusResponse,
    bad_request: ErrorResponse,
    forbidden: ErrorResponse,
};

/// Runtime makes this request in order to submit an error response. It can be
/// either a function error, or a runtime error. Error will be served in
/// response to the invoke.
///
/// `error_type` expects format _"category.reason"_ (example: _"Runtime.ConfigInvalid"_).
pub fn sendInvocationFail(
    arena: Allocator,
    client: *Client,
    path: []const u8,
    err: anyerror,
    message: []const u8,
    trace: ?ErrorTrace,
) Error!InvocationFailResult {
    const req = ErrorRequest.from(arena, "Handler", err, message, trace);
    const fetch = try sendError(arena, client, path, @errorName(err), req);
    return switch (fetch.status) {
        .accepted => .{ .accepted = try StatusResponse.parse(arena, fetch.body) },
        .bad_request => .{ .bad_request = try ErrorResponse.parse(arena, fetch.body) },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

pub const ErrorTrace = []const []const u8;
const ErrorRequest = struct {
    message: []const u8,
    error_type: []const u8,
    stack_trace: []const []const u8,

    pub fn from(allocator: Allocator, comptime cat: []const u8, err: anyerror, message: []const u8, trace: ?ErrorTrace) ErrorRequest {
        const err_type = std.fmt.allocPrint(allocator, cat ++ ".{s}", .{@errorName(err)}) catch @errorName(err);
        return .{
            .message = message,
            .error_type = err_type,
            .stack_trace = trace orelse &[_][]const u8{},
        };
    }
};

pub const ErrorResponse = struct {
    /// The error message.
    message: []const u8,

    /// The error type.
    error_type: []const u8,

    pub fn parse(arena: Allocator, json: []const u8) !ErrorResponse {
        const E = struct { errorMessage: []const u8, errorType: []const u8 };
        const parsed = std.json.parseFromSliceLeaky(E, arena, json, .{
            .allocate = .alloc_if_needed,
        }) catch return error.ParseError;
        return ErrorResponse{
            .message = parsed.errorMessage,
            .error_type = parsed.errorType,
        };
    }
};

pub const StatusResponse = struct {
    /// Status information.
    status: []const u8,

    pub fn parse(arena: Allocator, json: []const u8) !StatusResponse {
        const S = struct { status: []const u8 };
        const parsed = std.json.parseFromSliceLeaky(S, arena, json, .{
            .allocate = .alloc_if_needed,
        }) catch return error.ParseError;
        return StatusResponse{ .status = parsed.status };
    }
};

const RuntimeStatus = enum(u9) {
    success = 200,
    accepted = 202,
    bad_request = 400,
    forbidden = 403,
    payload_too_large = 413,
    /// Non-recoverable state.
    /// **runtime should exit promptly.**
    container_error = 500,
    _,
};

const ClientResult = Client.Result(RuntimeStatus);

fn sendRequest(
    arena: Allocator,
    client: *Client,
    method: Client.Method,
    path: []const u8,
    options: Client.Options,
) !ClientResult {
    return client.send(arena, RuntimeStatus, method, path, options) catch |e| {
        lambda.log_runtime.err("[Send Request] Client failed: {s}, Path: {s}", .{ @errorName(e), path });
        return error.ClientError;
    };
}

fn sendError(
    arena: Allocator,
    client: *Client,
    path: []const u8,
    err_type: []const u8,
    err_req: ErrorRequest,
) !ClientResult {
    return client.send(arena, RuntimeStatus, .POST, path, .{
        .request = .{
            .content_type = .{ .override = ERROR_CONTENT_TYPE },
        },
        .headers = &.{
            .{ .name = ERROR_HEAD_TYPE, .value = err_type },
        },
        .payload = try std.json.stringifyAlloc(arena, err_req, .{}),
    }) catch |e| {
        lambda.log_runtime.err("[Send Error] Client failed: {s}, Path: {s}", .{ @errorName(e), path });
        return error.ClientError;
    };
}
