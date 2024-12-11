const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");

const DEFAULT_MEMORY_MB: u16 = 128;
const DEFAULT_REGION: []const u8 = "us-east-1";
const DEFAULT_INIT_TYPE = Context.ConfigMeta.InitType.on_demand;

pub const Context = struct {
    /// The user owns the memory and **must deallocate it** by the end of the invocation.
    ///
    /// While it may be used to persist data and services between invocations,
    /// consider using _dependency injection_ or _Lambda Extension_ instead.
    gpa: std.mem.Allocator,
    /// An allocator tied to the invocation’s lifetime.
    /// The runtime will deallocate the memory on the user’s behalf after the invocation resolves.
    arena: std.mem.Allocator,
    /// Configuration metadata for the function.
    config: ConfigMeta = .{},
    /// Request metadata of the invocation.
    request: RequestMeta = .{},

    _force_destroy: *bool,
    _kv: *const std.process.EnvMap = undefined,

    /// Return the environmant value associated with a key.
    pub fn env(self: Context, key: []const u8) ?[]const u8 {
        return self._kv.get(key);
    }

    /// This will crash the runtime AFTER returning the response to the client.
    /// The Lambda execution environment will terminate the function instance.
    ///
    /// Warning: Use with caution! Only use this method when you assume the function
    /// won’t behave as expected in the following invocation.
    pub fn forceTerminateAfterResponse(self: Context) void {
        self._force_destroy.* = true;
    }

    pub const ConfigMeta = struct {
        /// Name of the function.
        func_name: []const u8 = "",

        /// Version of the function being executed.
        func_version: []const u8 = "",

        /// Amount of memory available to the function in MB.
        func_size: u16 = DEFAULT_MEMORY_MB,

        /// Initialization type of the function.
        func_init: InitType = DEFAULT_INIT_TYPE,

        /// Handler location configured on the function.
        func_handler: []const u8 = "",

        /// AWS Region where the Lambda function is executed.
        aws_region: []const u8 = DEFAULT_REGION,

        /// Access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
        aws_access_id: []const u8 = "",

        /// Access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
        aws_access_secret: []const u8 = "",

        /// Access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
        aws_session_token: []const u8 = "",

        /// Name of the Amazon CloudWatch Logs group for the function.
        log_group: []const u8 = "",

        /// Name of the Amazon CloudWatch Logs stream for the function.
        log_stream: []const u8 = "",

        pub const InitType = enum {
            on_demand,
            provisioned,
            snap_start,
        };
    };

    pub const RequestMeta = struct {
        /// AWS request ID associated with the request.
        id: []const u8 = "",

        /// X-Ray tracing id.
        xray_trace: []const u8 = "",

        /// The function ARN requested.
        /// This may be different for **each invoke** that executes the same version.
        invoked_arn: []const u8 = "",

        /// Function execution deadline counted in milliseconds since the _Unix epoch_.
        deadline_ms: u64 = 0,

        /// Information about the client application and device when invoked through the AWS Mobile SDK.
        client_context: []const u8 = "",

        /// Information about the Amazon Cognito identity provider when invoked through the AWS Mobile SDK.
        cognito_identity: []const u8 = "",
    };
};

/// Returns the URL (host and port) of the Runtime API.
/// https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html
pub fn loadMeta(ctx: *Context, env: *const std.process.EnvMap) void {
    const cfg = &ctx.config;
    ctx._kv = env;

    if (env.get("AWS_REGION")) |v|
        cfg.aws_region = v
    else if (env.get("AWS_DEFAULT_REGION")) |v|
        cfg.aws_region = v;

    if (env.get("AWS_ACCESS_KEY_ID")) |v|
        cfg.aws_access_id = v
    else if (env.get("AWS_ACCESS_KEY")) |v|
        cfg.aws_access_id = v;

    if (env.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")) |v| {
        cfg.func_size = std.fmt.parseUnsigned(u16, v, 10) catch DEFAULT_MEMORY_MB;
    }

    if (env.get("AWS_LAMBDA_INITIALIZATION_TYPE")) |v| {
        if (std.mem.eql(u8, v, "on-demand"))
            cfg.func_init = .on_demand
        else if (std.mem.eql(u8, v, "provisioned-concurrency"))
            cfg.func_init = .provisioned
        else if (std.mem.eql(u8, v, "snap-start"))
            cfg.func_init = .snap_start;
    }

    if (env.get("_HANDLER")) |v| cfg.func_handler = v;
    if (env.get("AWS_LAMBDA_FUNCTION_NAME")) |v| cfg.func_name = v;
    if (env.get("AWS_LAMBDA_FUNCTION_VERSION")) |v| cfg.func_version = v;
    if (env.get("AWS_LAMBDA_LOG_GROUP_NAME")) |v| cfg.log_group = v;
    if (env.get("AWS_LAMBDA_LOG_STREAM_NAME")) |v| cfg.log_stream = v;
    if (env.get("_X_AMZN_TRACE_ID")) |v| ctx.request.xray_trace = v;
    if (env.get("AWS_SESSION_TOKEN")) |v| cfg.aws_session_token = v;
    if (env.get("AWS_SECRET_ACCESS_KEY")) |v| cfg.aws_access_secret = v;
}

/// Update the event-sepcific metadata fields.
pub fn updateMeta(ctx: *Context, event: api.InvocationEvent) void {
    ctx.request.id = event.request_id;
    ctx.request.xray_trace = event.xray_trace;
    ctx.request.invoked_arn = event.invoked_arn;
    ctx.request.deadline_ms = event.deadline_ms;
    ctx.request.client_context = event.client_context;
    ctx.request.cognito_identity = event.cognito_identity;
}
