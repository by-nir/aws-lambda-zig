//! A simple HTTP client shared between the APIs.

const std = @import("std");
const testing = std.testing;
const http = std.http;
pub const Method = http.Method;
pub const Header = http.Header;
pub const RequestHeaders = http.Client.Request.Headers;
pub const HeaderIterator = http.HeaderIterator;
const lambda = @import("lambda.zig");

const MAX_HEADERS_SIZE = 16 * 1024;

const Self = @This();
pub const Error = error{FetchError} || std.mem.Allocator.Error;

client: http.Client,
body: std.ArrayList(u8),

pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) Self {
    return .{
        .client = http.Client{ .allocator = gpa },
        .body = std.ArrayList(u8).init(arena),
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.* = undefined;
}

pub fn Result(comptime Status: type) type {
    return struct {
        status: Status,
        headers: HeaderIterator,
        body: []const u8,
    };
}

pub const Options = struct {
    request: RequestHeaders = .{},
    headers: ?[]const Header = null,
    payload: ?[]const u8 = null,
};

pub fn send(
    self: *Self,
    comptime Status: type,
    method: Method,
    url: []const u8,
    options: Options,
) Error!Result(Status) {
    const headers_buffer = try self.body.allocator.alloc(u8, MAX_HEADERS_SIZE);
    const result = self.client.fetch(.{
        // Request
        .method = method,
        .location = .{ .url = url },
        .headers = options.request,
        .extra_headers = options.headers orelse &.{},
        .payload = options.payload,

        // Response
        .server_header_buffer = headers_buffer,
        .response_storage = .{ .dynamic = &self.body },
    }) catch |e| {
        lambda.log_runtime.err("[Fetcher] {s}\nMethod:{s}\nUrl:{s}\n", .{ @errorName(e), @tagName(method), url });
        return error.FetchError;
    };

    return Result(Status){
        .status = @enumFromInt(@intFromEnum(result.status)),
        .headers = HeaderIterator.init(headers_buffer),
        .body = try self.body.toOwnedSlice(),
    };
}
