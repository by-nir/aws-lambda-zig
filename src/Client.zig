//! A simple HTTP client shared between the APIs.

const std = @import("std");
const testing = std.testing;
const Client = std.http.Client;
pub const Method = std.http.Method;
pub const Header = std.http.Header;
pub const Reader = Client.Request.Reader;
pub const RequestHeaders = Client.Request.Headers;
pub const HeaderIterator = std.http.HeaderIterator;
const lambda = @import("lambda.zig");

const MAX_HEAD_BUFFER = 16 * 1024;
const MAX_BODY_BUFFER = 2 * 1024 * 1024;
const USER_AGENT = "aws-lambda-zig/" ++ @import("builtin").zig_version_string;

const Self = @This();

http: Client,
uri: std.Uri,

pub fn init(gpa: std.mem.Allocator, origin: []const u8) !Self {
    const idx = std.mem.indexOfScalar(u8, origin, ':');
    const uri = std.Uri{
        .path = "",
        .scheme = "http",
        .host = if (idx) |i| origin[0..i] else origin,
        .port = if (idx) |i|
            try std.fmt.parseUnsigned(u16, origin[i + 1 .. origin.len], 10)
        else
            null,
    };

    return .{
        .http = Client{ .allocator = gpa },
        .uri = uri,
    };
}

pub fn deinit(self: *Self) void {
    self.http.deinit();
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
    request: RequestHeaders = .{
        .user_agent = .{ .override = USER_AGENT },
    },
    headers: ?[]const Header = null,
    payload: ?[]const u8 = null,
    keep_alive: bool = false,
    chunked: bool = false,
};

pub fn send(self: *Self, arena: std.mem.Allocator, comptime Status: type, method: Method, path: []const u8, options: Options) !Result(Status) {
    var uri = self.uri;
    uri.path = path;

    var server_header_buffer: [MAX_HEAD_BUFFER]u8 = undefined;

    var headers = options.request;
    if (headers.user_agent == .default) {
        headers.user_agent = .{ .override = USER_AGENT };
    }

    var req = try self.http.open(method, uri, .{
        .keep_alive = options.keep_alive,
        .redirect_behavior = .not_allowed,
        .headers = headers,
        .extra_headers = options.headers orelse &.{},
        .server_header_buffer = &server_header_buffer,
    });
    defer req.deinit();

    if (options.payload) |payload| {
        req.transfer_encoding = if (options.chunked)
            .chunked
        else
            .{ .content_length = payload.len };
    }

    try req.send(.{});

    if (options.payload) |payload| {
        try req.writeAll(payload);
    }

    try req.finish();
    try req.wait();

    return Result(Status){
        .status = @enumFromInt(@intFromEnum(req.response.status)),
        .headers = HeaderIterator.init(&server_header_buffer),
        .body = try req.reader().readAllAlloc(arena, MAX_BODY_BUFFER),
    };
}
