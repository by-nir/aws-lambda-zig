//! Returns the function’s metadata, environment variables and the provided payload.
//!
//! 🛑 WARNING 🛑 Deploy with caution! This demo may expose sensitive data to the public.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.handle(handler, .{});
}

fn handler(allocs: lambda.Allocators, ctx: lambda.Context, event: []const u8) ![]const u8 {
    var str = try std.ArrayList(u8).initCapacity(allocs.arena, 1024);
    const writer = str.writer();
    try writer.print(
        "{{\"function_meta\":{{\"api_origin\":\"{s}\",\"aws_region\":\"{s}\",\"aws_access_id\":\"{s}\",\"aws_access_secret\":\"{s}\",\"aws_session_token\":\"{s}\",\"function_name\":\"{s}\",\"function_version\":\"{s}\",\"function_size\":{d},\"function_init_type\":\"{s}\",\"function_handler\":\"{s}\",\"log_group\":\"{s}\",\"log_stream\":\"{s}\"}},",
        .{ ctx.api_origin, ctx.aws_region, ctx.aws_access_id, ctx.aws_access_secret, ctx.aws_session_token, ctx.function_name, ctx.function_version, ctx.function_size, @tagName(ctx.function_init_type), ctx.function_handler, ctx.log_group, ctx.log_stream },
    );
    try writer.print(
        "\"invocation_meta\":{{\"request_id\":\"{s}\",\"xray_trace\":\"{s}\",\"invoked_arn\":\"{s}\",\"deadline_ms\":{d},\"client_context\":\"{s}\",\"cognito_identity\":\"{s}\"}},\"payload\":{s},\"env\":{{",
        .{ ctx.request_id, ctx.xray_trace, ctx.invoked_arn, ctx.deadline_ms, ctx.client_context, ctx.cognito_identity, event },
    );
    var it = ctx.env.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) {
        const prefix: []const u8 = if (i > 0) "," else "";
        const fmt = "{s}\"{s}\":\"{s}\"";
        try writer.print(fmt, .{ prefix, kv.key_ptr.*, kv.value_ptr.* });
    }
    try writer.writeAll("}}");
    return str.toOwnedSlice();
}
