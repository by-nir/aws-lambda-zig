const std = @import("std");

/// The runtime’s logging scope.
pub const log_runtime = std.log.scoped(.Runtime);

/// The handler’s logging scope.
pub const log_handler = std.log.scoped(.Handler);

pub const Allocators = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
};

pub const handlerFn = *const fn (
    allocs: Allocators,
    context: *const Context,
    /// The event’s JSON payload
    event: []const u8,
) anyerror![]const u8;

pub const Context = struct {
    const DEFAULT_REGION: []const u8 = "us-east-1";
    const DEFAULT_MEMORY_MB: u16 = 128;
    const DEFAULT_INIT_TYPE = InitType.on_demand;

    pub const InitType = enum {
        on_demand,
        provisioned,
        snap_start,
    };

    //
    // Function Meta
    //

    /// Environment variables; user-provided and [function meta](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html#configuration-envvars-runtime).
    env: *const std.process.EnvMap,

    /// Host and port of the [runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html).
    api_host: []const u8 = undefined,

    /// AWS Region where the Lambda function is executed.
    aws_region: []const u8 = DEFAULT_REGION,

    /// Access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
    aws_access_id: []const u8 = &[_]u8{},

    /// Access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
    aws_access_secret: []const u8 = &[_]u8{},

    /// Access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
    aws_session_token: []const u8 = &[_]u8{},

    /// Name of the function.
    function_name: []const u8 = &[_]u8{},

    /// Version of the function being executed.
    function_version: []const u8 = &[_]u8{},

    /// Amount of memory available to the function in MB.
    function_size: u16 = DEFAULT_MEMORY_MB,

    /// Initialization type of the function.
    function_init_type: InitType = DEFAULT_INIT_TYPE,

    /// Handler location configured on the function.
    function_handler: []const u8 = &[_]u8{},

    /// Name of the Amazon CloudWatch Logs group for the function.
    log_group: []const u8 = &[_]u8{},

    /// Name of the Amazon CloudWatch Logs stream for the function.
    log_stream: []const u8 = &[_]u8{},

    //
    // Invocation Meta
    //

    /// AWS request ID associated with the request.
    request_id: []const u8 = &[_]u8{},

    /// X-Ray tracing id.
    xray_trace: []const u8 = &[_]u8{},

    /// The function ARN requested.
    ///
    /// **This can be different in each invoke** that executes the same version.
    invoked_arn: []const u8 = &[_]u8{},

    /// Function execution deadline counted in milliseconds since the _Unix epoch_.
    deadline_ms: u64 = 0,

    /// Information about the client application and device when invoked through the AWS Mobile SDK.
    client_context: []const u8 = &[_]u8{},

    /// Information about the Amazon Cognito identity provider when invoked through the AWS Mobile SDK.
    cognito_identity: []const u8 = &[_]u8{},

    //
    // Methods
    //

    pub fn init(allocator: std.mem.Allocator) !Context {
        var env = try loadEnv(allocator);
        errdefer env.deinit();

        var self = Context{ .env = env };

        if (env.get("AWS_LAMBDA_RUNTIME_API")) |v| {
            self.api_host = v;
        } else {
            return error.MissingRuntimeHost;
        }

        if (env.get("AWS_REGION")) |v| {
            self.aws_region = v;
        } else if (env.get("AWS_DEFAULT_REGION")) |v| {
            self.aws_region = v;
        }

        if (env.get("AWS_ACCESS_KEY_ID")) |v| {
            self.aws_access_id = v;
        } else if (env.get("AWS_ACCESS_KEY")) |v| {
            self.aws_access_id = v;
        }

        if (env.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")) |v| {
            if (std.fmt.parseUnsigned(u16, v, 10)) |d| {
                self.function_size = d;
            } else |_| {}
        }

        if (env.get("AWS_LAMBDA_INITIALIZATION_TYPE")) |v| {
            if (std.mem.eql(u8, v, "on-demand")) {
                self.function_init_type = .on_demand;
            } else if (std.mem.eql(u8, v, "provisioned-concurrency")) {
                self.function_init_type = .provisioned;
            } else if (std.mem.eql(u8, v, "snap-start")) {
                self.function_init_type = .snap_start;
            }
        }

        if (env.get("AWS_SECRET_ACCESS_KEY")) |v| self.aws_access_secret = v;
        if (env.get("AWS_SESSION_TOKEN")) |v| self.aws_session_token = v;
        if (env.get("AWS_LAMBDA_FUNCTION_NAME")) |v| self.function_name = v;
        if (env.get("AWS_LAMBDA_FUNCTION_VERSION")) |v| self.function_version = v;
        if (env.get("_HANDLER")) |v| self.function_handler = v;
        if (env.get("AWS_LAMBDA_LOG_GROUP_NAME")) |v| self.log_group = v;
        if (env.get("AWS_LAMBDA_LOG_STREAM_NAME")) |v| self.log_stream = v;
        if (env.get("_X_AMZN_TRACE_ID")) |v| self.xray_trace = v;

        return self;
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        @constCast(self.env).hash_map.deinit();
        allocator.destroy(self.env);
    }

    fn loadEnv(allocator: std.mem.Allocator) !*std.process.EnvMap {
        const env = try allocator.create(std.process.EnvMap);
        env.* = std.process.EnvMap.init(allocator);

        if (@import("builtin").link_libc) {
            var ptr = std.c.environ;
            while (ptr[0]) |line| : (ptr += 1) try parseAndPutVar(env, line);
        } else {
            for (std.os.environ) |line| try parseAndPutVar(env, line);
        }
        return env;
    }

    // Based on std.process.getEnvMap
    fn parseAndPutVar(map: *std.process.EnvMap, line: [*]u8) !void {
        var line_i: usize = 0;
        while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
        const key = line[0..line_i];

        var end_i: usize = line_i;
        while (line[end_i] != 0) : (end_i += 1) {}
        const value = line[line_i + 1 .. end_i];

        try map.putMove(key, value);
    }
};
