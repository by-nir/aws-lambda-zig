//! A simple HTTP client shared between the APIs.

const std = @import("std");
const testing = std.testing;
const Client = std.http.Client;
const Allocator = std.mem.Allocator;
const lambda = @import("lambda.zig");

const MAX_HEAD_BUFFER = 16 * 1024;
const MAX_BODY_BUFFER = 2 * 1024 * 1024;
const USER_AGENT = "aws-lambda-zig/" ++ @import("builtin").zig_version_string;

const Self = @This();
pub const Header = std.http.Header;
pub const Request = Client.Request;
pub const HeaderIterator = std.http.HeaderIterator;

var response_headers: [MAX_HEAD_BUFFER]u8 = undefined;

http: Client,
uri: std.Uri,

pub fn init(gpa: Allocator, origin: []const u8) !Self {
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

pub const Options = struct {
    headers: ?[]const Header = null,
    request: Request.Headers = .{},
};

pub const Result = struct {
    status: std.http.Status,
    headers: HeaderIterator,
    body: []const u8,
};

// Based on std.Http.Client.fetch
pub fn send(self: *Self, arena: Allocator, path: []const u8, payload: ?[]const u8, options: Options) !Result {
    const uri = self.uriFor(path);
    const headers = prepareHeaders(options.request);
    const method: std.http.Method = if (payload == null) .GET else .POST;
    var req = try self.http.open(method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .server_header_buffer = &response_headers,
        .headers = headers,
        .extra_headers = options.headers orelse &.{},
    });
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
    }
    try req.send(.{});

    if (payload) |p| {
        try req.writeAll(p);
    }

    try req.finish();
    return respond(&req, arena);
}

fn uriFor(self: *Self, path: []const u8) std.Uri {
    var uri = self.uri;
    uri.path = path;
    return uri;
}

fn prepareHeaders(request: Request.Headers) Request.Headers {
    var headers = request;
    if (headers.user_agent == .default) {
        headers.user_agent = .{ .override = USER_AGENT };
    }
    return headers;
}

fn respond(req: *Client.Request, arena: Allocator) !Result {
    try req.wait();

    var body: []const u8 = &.{};
    const content_length = req.response.content_length;
    if (content_length != null and content_length.? > 0) {
        body = try req.reader().readAllAlloc(arena, MAX_BODY_BUFFER);
    }

    return Result{
        .status = req.response.status,
        .headers = HeaderIterator.init(&response_headers),
        .body = body,
    };
}
