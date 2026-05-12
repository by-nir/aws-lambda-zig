//! Returns the function’s metadata, environment variables, and the provided payload.
//!
//! 🛑 WARNING 🛑 Deploy with caution! This demo may expose sensitive data to the public.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, payload: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = try .initCapacity(ctx.arena, 1024);
    const w = &output.writer;

    try w.writeByte('{');

    // Payload
    try w.print("\"payload\":{s}", .{payload});

    // Function metadata
    const cfg = ctx.config;
    try w.writeAll(",\"function_meta\":{");
    try w.print("\"aws_region\":\"{s}\",", .{cfg.aws_region});
    try w.print("\"aws_access_id\":\"{s}\",", .{cfg.aws_access_id});
    try w.print("\"aws_access_secret\":\"{s}\",", .{cfg.aws_access_secret});
    try w.print("\"aws_session_token\":\"{s}\",", .{cfg.aws_session_token});
    try w.print("\"function_name\":\"{s}\",", .{cfg.func_name});
    try w.print("\"function_version\":\"{s}\",", .{cfg.func_version});
    try w.print("\"function_size\":{d},", .{cfg.func_size});
    try w.print("\"function_init_type\":\"{s}\",", .{@tagName(cfg.func_init)});
    try w.print("\"function_handler\":\"{s}\",", .{cfg.func_handler});
    try w.print("\"log_group\":\"{s}\",", .{cfg.log_group});
    try w.print("\"log_stream\":\"{s}\"", .{cfg.log_stream});
    try w.writeByte('}');

    // Runtime metadata
    const meta = try ctx.runtimeMetadata();
    try w.writeAll(",\"runtime_meta\":{");
    try w.print("\"availability_zone_id\":\"{s}\"", .{meta.availability_zone_id});
    try w.writeByte('}');

    // Invocation metadata
    const req = ctx.request;
    try w.writeAll(",\"invocation_meta\":{");
    try w.print("\"request_id\":\"{s}\",", .{req.id});
    try w.print("\"xray_trace\":\"{s}\",", .{req.xray_trace});
    try w.print("\"invoked_arn\":\"{s}\",", .{req.invoked_arn});
    try w.print("\"deadline_ms\":{d},", .{req.deadline_ms});
    try w.print("\"client_context\":\"{s}\",", .{req.client_context});
    try w.print("\"cognito_identity\":\"{s}\"", .{req.cognito_identity});
    try w.writeByte('}');

    try w.writeByte('}');
    return output.toOwnedSlice();
}
