//! Returns the function’s metadata, environment variables and the provided payload.
//!
//! 🛑 WARNING 🛑 Deploy with caution! This demo may expose sensitive data to the public.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.handle(handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    var str: std.Io.Writer.Allocating = try .initCapacity(ctx.arena, 1024);

    const cfg = ctx.config;
    try str.writer.print(
        "{{\"function_meta\":{{\"aws_region\":\"{s}\",\"aws_access_id\":\"{s}\",\"aws_access_secret\":\"{s}\",\"aws_session_token\":\"{s}\",\"function_name\":\"{s}\",\"function_version\":\"{s}\",\"function_size\":{d},\"function_init_type\":\"{s}\",\"function_handler\":\"{s}\",\"log_group\":\"{s}\",\"log_stream\":\"{s}\"}},",
        .{
            cfg.aws_region,
            cfg.aws_access_id,
            cfg.aws_access_secret,
            cfg.aws_session_token,
            cfg.func_name,
            cfg.func_version,
            cfg.func_size,
            @tagName(cfg.func_init),
            cfg.func_handler,
            cfg.log_group,
            cfg.log_stream,
        },
    );

    const req = ctx.request;
    try str.writer.print(
        "\"invocation_meta\":{{\"request_id\":\"{s}\",\"xray_trace\":\"{s}\",\"invoked_arn\":\"{s}\",\"deadline_ms\":{d},\"client_context\":\"{s}\",\"cognito_identity\":\"{s}\"}},\"payload\":{s}}}",
        .{
            req.id,
            req.xray_trace,
            req.invoked_arn,
            req.deadline_ms,
            req.client_context,
            req.cognito_identity,
            event,
        },
    );

    return str.toOwnedSlice();
}
