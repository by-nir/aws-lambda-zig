const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const Client = @import("../utils/Http.zig");
const log = @import("../utils/log.zig").runtime;

pub const ENV_ORIGIN = "AWS_LAMBDA_RUNTIME_API";

const URL_BASE = "/2018-06-01/runtime/";
const URL_INIT_FAIL: []const u8 = URL_BASE ++ "init/error";
const URL_INVOC_NEXT: []const u8 = URL_BASE ++ "invocation/next";
const URL_INVOC_SUCCESS: []const u8 = URL_BASE ++ "invocation/{s}/response";
const URL_INVOC_FAIL: []const u8 = URL_BASE ++ "invocation/{s}/error";
const URL_ERROR = "[{s}] Interpreting URL failed: {s}";

const ERROR_HEAD_TYPE = "Lambda-Runtime-Function-Error-Type";
const ERROR_HEAD_BODY = "Lambda-Runtime-Function-Error-Body";
const ERROR_CONTENT_TYPE = "application/vnd.aws.lambda.error+json";

const STREAM_HEAD_NAME = "Lambda-Runtime-Function-Response-Mode";
const STREAM_HEAD_VAL = "streaming";

pub const Error = error{ ParseError, ClientError, ContainerError, UnknownStatus } || Allocator.Error;

pub const ErrorRequest = struct {
    type: anyerror,
    message: []const u8,
    // stack_trace: ?[]const []const u8,
};

pub const ErrorResponse = struct {
    /// The error message.
    message: []const u8,

    /// The error type.
    type: []const u8,

    pub fn parse(arena: Allocator, json: []const u8) !ErrorResponse {
        const E = struct { errorMessage: []const u8, errorType: []const u8 };
        const parsed = std.json.parseFromSliceLeaky(E, arena, json, .{
            .allocate = .alloc_if_needed,
        }) catch return error.ParseError;
        return ErrorResponse{
            .message = parsed.errorMessage,
            .type = parsed.errorType,
        };
    }
};

/// Non-recoverable initialization error. Runtime should exit after reporting
/// the error. Error will be served in response to the first invoke.
pub fn sendInitFail(arena: Allocator, client: *Client, err: ErrorRequest) Error!InitFailResult {
    const result = try sendError(arena, client, URL_INIT_FAIL, "Runtime", err);
    return InitFailResult.init(arena, result);
}

/// This is an iterator-style blocking API call. Runtime makes this request when
/// it is ready to process a new invoke.
pub fn sendInvocationNext(arena: Allocator, client: *Client) Error!InvocationNextResult {
    var result = try sendRequest(arena, client, URL_INVOC_NEXT, null);
    return InvocationNextResult.init(arena, &result);
}

/// Runtime makes this request in order to submit a response.
pub fn sendInvocationSuccess(
    arena: Allocator,
    client: *Client,
    req_id: []const u8,
    payload: []const u8,
) Error!InvocationSuccessResult {
    const path = try requestPath(arena, URL_INVOC_SUCCESS, req_id, "Invocation Success");
    var result = try sendRequest(arena, client, path, payload);
    return InvocationSuccessResult.init(arena, &result);
}

/// Runtime makes this request in order to stream a response.
pub fn streamInvocationOpen(
    arena: Allocator,
    client: *Client,
    req_id: []const u8,
    content_type: []const u8,
    comptime raw_http_prelude: []const u8,
    args: anytype,
) Error!Client.Request {
    const path = try requestPath(arena, URL_INVOC_SUCCESS, req_id, "Invocation Success");
    return client.streamOpen(path, .{
        .request = .{
            .authorization = .omit,
            .accept_encoding = .omit,
            .content_type = .{ .override = content_type },
        },
        .headers = &[_]Client.Header{
            .{ .name = STREAM_HEAD_NAME, .value = STREAM_HEAD_VAL },
            .{ .name = "Trailer", .value = ERROR_HEAD_TYPE },
            .{ .name = "Trailer", .value = ERROR_HEAD_BODY },
        },
    }, raw_http_prelude, args) catch |e| {
        log.err("[Stream Request] Client failed opening: {s}, Path: {s}", .{ @errorName(e), path });
        return error.ClientError;
    };
}

/// Close the stream.
///
/// Trailer headers are optional.
pub fn streamInvocationClose(
    req: *Client.Request,
    arena: Allocator,
    err_req: ?ErrorRequest,
) Error!InvocationSuccessResult {
    const trailer: ?[]const Client.Header = if (err_req) |err| blk: {
        const err_type = std.fmt.allocPrint(arena, "Handler.{s}", .{@errorName(err.type)}) catch |e| {
            log.err("[Send Error] Formatting error type failed: {s}", .{@errorName(e)});
            return error.ClientError;
        };

        const body = formatError(arena, "Handler", err) catch |e| {
            log.err("[Send Error] Formatting error body failed: {s}", .{@errorName(e)});
            return error.ClientError;
        };
        const size = std.base64.standard.Encoder.calcSize(body.len);
        const body_encoded = arena.alloc(u8, size) catch |e| {
            log.err("[Send Error] Encoding error body failed: {s}", .{@errorName(e)});
            return error.ClientError;
        };
        _ = std.base64.standard.Encoder.encode(body_encoded, body);

        break :blk &[_]Client.Header{
            .{ .name = ERROR_HEAD_TYPE, .value = err_type },
            .{ .name = ERROR_HEAD_BODY, .value = body_encoded },
        };
    } else null;

    var result = Client.streamClose(arena, req, trailer) catch |e| {
        log.err("[Stream Request] Client failed closing: {s}", .{@errorName(e)});
        return error.ClientError;
    };
    return InvocationSuccessResult.init(arena, &result);
}

/// Runtime makes this request in order to submit an error response. It can be
/// either a function error, or a runtime error. Error will be served in
/// response to the invoke.
pub fn sendInvocationFail(
    arena: Allocator,
    client: *Client,
    req_id: []const u8,
    err: ErrorRequest,
) Error!InvocationFailResult {
    const path = try requestPath(arena, URL_INVOC_SUCCESS, req_id, "Invocation Fail");
    const result = try sendError(arena, client, path, "Handler", err);
    return InvocationFailResult.init(arena, result);
}

fn requestPath(
    arena: Allocator,
    comptime fmt: []const u8,
    req_id: []const u8,
    err_phase: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(arena, fmt, .{req_id}) catch |e| {
        log.err(URL_ERROR, .{ err_phase, @errorName(e) });
        return e;
    };
}

fn sendError(
    arena: Allocator,
    client: *Client,
    path: []const u8,
    err_category: []const u8,
    err: ErrorRequest,
) !Client.Result {
    const head = Client.Header{
        .name = ERROR_HEAD_TYPE,
        .value = @errorName(err.type),
    };

    const payload = formatError(arena, err_category, err) catch |e| {
        log.err("[Send Error] Formatting error failed: {s}", .{@errorName(e)});
        return error.ClientError;
    };

    return client.send(arena, path, payload, .{
        .headers = &.{head},
        .request = .{
            .authorization = .omit,
            .accept_encoding = .omit,
            .content_type = .{ .override = ERROR_CONTENT_TYPE },
        },
    }) catch |e| {
        log.err("[Send Error] Client failed: {s}, Path: {s}", .{ @errorName(e), path });
        return error.ClientError;
    };
}

fn sendRequest(arena: Allocator, client: *Client, path: []const u8, payload: ?[]const u8) !Client.Result {
    return client.send(arena, path, payload, .{}) catch |e| {
        log.err("[Send Request] Client failed: {s}, Path: {s}", .{ @errorName(e), path });
        return error.ClientError;
    };
}

fn formatError(arena: Allocator, err_category: []const u8, err: ErrorRequest) ![]const u8 {
    var buffer = std.ArrayList(u8).init(arena);
    const writer = buffer.writer();

    try writer.print(
        \\{{"errorType":"{s}.
    , .{err_category});
    try std.json.encodeJsonStringChars(@errorName(err.type), .{}, writer);
    try writer.writeAll(
        \\","errorMessage":"
    );
    try std.json.encodeJsonStringChars(err.message, .{}, writer);
    try writer.writeAll(
        \\","stackTrace":[]}
    );

    return buffer.toOwnedSlice();
}

const Status = enum(u9) {
    success = 200,
    accepted = 202,
    bad_request = 400,
    forbidden = 403,
    payload_too_large = 413,
    /// Non-recoverable state.
    /// **runtime should exit promptly.**
    container_error = 500,
    _,

    pub fn from(http: std.http.Status) Status {
        return @enumFromInt(@intFromEnum(http));
    }
};

const StatusResponse = struct {
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

    pub fn parse(arena: Allocator, result: *Client.Result) !InvocationEvent {
        var event = std.mem.zeroInit(InvocationEvent, .{
            .payload = result.body,
        });

        while (result.headers.next()) |header| {
            if (mem.eql(u8, "Lambda-Runtime-Aws-Request-Id", header.name))
                event.request_id = try arena.dupe(u8, header.value)
            else if (mem.eql(u8, "Lambda-Runtime-Trace-Id", header.name))
                event.xray_trace = try arena.dupe(u8, header.value)
            else if (mem.eql(u8, "Lambda-Runtime-Invoked-Function-Arn", header.name))
                event.invoked_arn = try arena.dupe(u8, header.value)
            else if (mem.eql(u8, "Lambda-Runtime-Deadline-Ms", header.name))
                event.deadline_ms = std.fmt.parseInt(u64, header.value, 10) catch 0
            else if (mem.eql(u8, "Lambda-Runtime-Client-Context", header.name))
                event.client_context = try arena.dupe(u8, header.value)
            else if (mem.eql(u8, "Lambda-Runtime-Cognito-Identity", header.name))
                event.cognito_identity = try arena.dupe(u8, header.value);
        }

        return event;
    }

    /// Remaining time in **milliseconds** before the function execution aborts.
    pub fn remaining(self: InvocationEvent) u64 {
        return @as(u64, @intCast(std.time.milliTimestamp())) - self.deadline_timestamp;
    }
};

const InitFailResult = union(enum) {
    accepted: StatusResponse,
    forbidden: ErrorResponse,

    pub fn init(arena: Allocator, result: Client.Result) Error!InitFailResult {
        return switch (Status.from(result.status)) {
            .accepted => .{ .accepted = try StatusResponse.parse(arena, result.body) },
            .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, result.body) },
            .container_error => error.ContainerError,
            else => error.UnknownStatus,
        };
    }
};

const InvocationNextResult = union(enum) {
    success: InvocationEvent,
    forbidden: ErrorResponse,

    pub fn init(arena: Allocator, result: *Client.Result) Error!InvocationNextResult {
        return switch (Status.from(result.status)) {
            .success => .{ .success = try InvocationEvent.parse(arena, result) },
            .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, result.body) },
            .container_error => error.ContainerError,
            else => error.UnknownStatus,
        };
    }
};

const InvocationSuccessResult = union(enum) {
    accepted: StatusResponse,
    bad_request: ErrorResponse,
    forbidden: ErrorResponse,
    payload_too_large: ErrorResponse,

    pub fn init(arena: Allocator, result: *Client.Result) Error!InvocationSuccessResult {
        return switch (Status.from(result.status)) {
            .accepted => .{ .accepted = try StatusResponse.parse(arena, result.body) },
            .bad_request => .{ .bad_request = try ErrorResponse.parse(arena, result.body) },
            .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, result.body) },
            .payload_too_large => .{ .payload_too_large = try ErrorResponse.parse(arena, result.body) },
            .container_error => error.ContainerError,
            else => error.UnknownStatus,
        };
    }
};

const InvocationFailResult = union(enum) {
    accepted: StatusResponse,
    bad_request: ErrorResponse,
    forbidden: ErrorResponse,

    pub fn init(arena: Allocator, result: Client.Result) Error!InvocationFailResult {
        return switch (Status.from(result.status)) {
            .accepted => .{ .accepted = try StatusResponse.parse(arena, result.body) },
            .bad_request => .{ .bad_request = try ErrorResponse.parse(arena, result.body) },
            .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, result.body) },
            .container_error => error.ContainerError,
            else => error.UnknownStatus,
        };
    }
};
