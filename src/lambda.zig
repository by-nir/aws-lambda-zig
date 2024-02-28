const std = @import("std");

pub const log_runtime = std.log.scoped(.Runtime);
pub const log_handler = std.log.scoped(.Handler);

pub const Context = struct {
    /// The function ARN requested.
    ///
    /// **This can be different in each invoke** that executes the same version.
    invoked_arn: []const u8,

    /// Function execution deadline counted in milliseconds since the _Unix epoch_.
    deadline_ms: u64,

    /// The environment variables available provided by Lambda.
    env_reserved: *const ReservedEnv,
};

/// [AWS Docs](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html#configuration-envvars-runtime)
pub const ReservedEnv = struct {
    const DEFAULT_REGION: []const u8 = "us-east-1";
    const DEFAULT_INIT_TYPE = InitType.on_demand;
    const DEFAULT_MEMORY_MB: u16 = 128;

    pub const InitType = enum {
        on_demand,
        provisioned,
        snap_start,
    };

    /// AWS Region where the Lambda function is executed.
    aws_region: []const u8 = &[_]u8{},

    /// An access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
    aws_access_key: []const u8 = &[_]u8{},

    /// An access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
    aws_access_key_id: []const u8 = &[_]u8{},

    /// An access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
    aws_secret_access_key: []const u8 = &[_]u8{},

    /// An access key obtained from the function's [execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html).
    aws_session_token: []const u8 = &[_]u8{},

    /// The host and port of the [runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html).
    runtime_api: []const u8,

    /// The name of the function.
    function_name: []const u8 = &[_]u8{},

    /// The version of the function being executed.
    function_version: []const u8 = &[_]u8{},

    /// The amount of memory available to the function in MB.
    function_size: u16 = DEFAULT_MEMORY_MB,

    /// The handler location configured on the function.
    function_handler: []const u8 = &[_]u8{},

    /// The initialization type of the function.
    function_init_type: InitType = DEFAULT_INIT_TYPE,

    /// The name of the Amazon CloudWatch Logs group for the function.
    log_group: []const u8 = &[_]u8{},

    /// The name of the Amazon CloudWatch Logs stream for the function.
    log_stream: []const u8 = &[_]u8{},

    /// The X-Ray tracing header.
    ///
    /// This value changes with each invocation.
    xray_trace: []const u8 = &[_]u8{},

    pub fn load() !ReservedEnv {
        const region = std.os.getenv("AWS_REGION") orelse
            std.os.getenv("AWS_DEFAULT_REGION") orelse
            DEFAULT_REGION;

        const size = if (std.os.getenv("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")) |str|
            std.fmt.parseUnsigned(u16, str, 10) catch DEFAULT_MEMORY_MB
        else
            DEFAULT_MEMORY_MB;

        const init_type: InitType = if (std.os.getenv("AWS_LAMBDA_INITIALIZATION_TYPE")) |str|
            if (std.mem.eql(u8, str, "on-demand"))
                .on_demand
            else if (std.mem.eql(u8, str, "provisioned-concurrency"))
                .provisioned
            else if (std.mem.eql(u8, str, "snap-start"))
                .snap_start
            else
                DEFAULT_INIT_TYPE
        else
            DEFAULT_INIT_TYPE;

        return .{
            .aws_region = region,
            .aws_access_key = std.os.getenv("AWS_ACCESS_KEY_ID") orelse &[_]u8{},
            .aws_access_key_id = std.os.getenv("AWS_ACCESS_KEY_ID") orelse &[_]u8{},
            .aws_secret_access_key = std.os.getenv("AWS_SECRET_ACCESS_KEY") orelse &[_]u8{},
            .aws_session_token = std.os.getenv("AWS_SESSION_TOKEN") orelse &[_]u8{},
            .runtime_api = std.os.getenv("AWS_LAMBDA_RUNTIME_API") orelse return error.NoEnvRuntimeApi,
            .function_name = std.os.getenv("AWS_LAMBDA_FUNCTION_NAME") orelse &[_]u8{},
            .function_version = std.os.getenv("AWS_LAMBDA_FUNCTION_VERSION") orelse &[_]u8{},
            .function_size = size,
            .function_handler = std.os.getenv("_HANDLER") orelse &[_]u8{},
            .function_init_type = init_type,
            .log_group = std.os.getenv("AWS_LAMBDA_LOG_GROUP_NAME") orelse &[_]u8{},
            .log_stream = std.os.getenv("AWS_LAMBDA_LOG_STREAM_NAME") orelse &[_]u8{},
            .xray_trace = std.os.getenv("_X_AMZN_TRACE_ID") orelse &[_]u8{},
        };
    }
};
