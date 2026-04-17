//! A simple HTTP client shared between the APIs.
const std = @import("std");
const testing = std.testing;
const Client = std.http.Client;
const Io = std.Io;
const Threaded = std.Io.Threaded;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const package_version = @import("meta.zig").package_version;

pub const Header = std.http.Header;
pub const Request = Client.Request;
pub const BodyWriter = std.http.BodyWriter;
pub const HeaderIterator = std.http.HeaderIterator;

const Self = @This();
const USER_AGENT = std.fmt.comptimePrint(
    "aws-lambda-zig/{s} (Zig/{s})",
    .{ package_version, builtin.zig_version_string },
);

client: Client,
uri: std.Uri,

pub fn init(self: *Self, gpa: Allocator, origin: []const u8, io: Io) !void {
    const idx = std.mem.indexOfScalar(u8, origin, ':');
    self.uri = std.Uri{
        .path = .{ .percent_encoded = "" },
        .scheme = "http",
        .host = .{ .raw = if (idx) |i| origin[0..i] else origin },
        .port = if (idx) |i|
            try std.fmt.parseUnsigned(u16, origin[i + 1 .. origin.len], 10)
        else
            null,
    };

    self.client = Client{ .allocator = gpa, .io = io };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.* = undefined;
}

pub const Options = struct {
    request: Request.Headers = .{},
    headers: ?[]const Header = null,
};

pub const Result = struct {
    status: std.http.Status,
    headers: HeaderIterator,
    body: []const u8,
};

pub fn send(self: *Self, arena: Allocator, path: []const u8, payload: ?[]const u8, options: Options) !Result {
    const uri = self.uriFor(path);
    const method: std.http.Method = if (payload == null) .GET else .POST;
    var req = try self.client.request(method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .headers = prepareHeaders(options.request),
        .extra_headers = options.headers orelse &.{},
    });
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = try req.sendBody(&.{});
        try body.writer.writeAll(p);
        try body.end();
    } else {
        try req.sendBodiless();
    }

    const redirect_buffer: [0]u8 = undefined;
    var res = try req.receiveHead(&redirect_buffer);
    return parseResponse(arena, &res);
}

pub fn openStream(
    self: *Self,
    path: []const u8,
    options: Options,
    comptime prelude_raw: []const u8,
    prelude_args: anytype,
) !struct { Request, BodyWriter } {
    const uri = self.uriFor(path);
    var req = try self.client.request(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .headers = prepareHeaders(options.request),
        .extra_headers = options.headers orelse &.{},
    });
    errdefer req.deinit();

    req.transfer_encoding = .chunked;

    if (prelude_raw.len == 0) {
        const body = try req.sendBody(&.{});
        return .{ req, body };
    } else {
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.print(prelude_raw, prelude_args);
        try body.flush();
        return .{ req, body };
    }
}

pub fn closeStream(arena: Allocator, req: *Request, body: *BodyWriter, trailers: []const Header) !Result {
    defer req.deinit();

    try body.endChunked(.{
        .trailers = trailers,
    });

    var res = try req.receiveHead(&.{});
    return parseResponse(arena, &res);
}

fn uriFor(self: *Self, path: []const u8) std.Uri {
    var uri = self.uri;
    uri.path = .{ .raw = path };
    return uri;
}

fn prepareHeaders(request: Request.Headers) Request.Headers {
    var headers = request;
    if (headers.user_agent == .default) {
        headers.user_agent = .{ .override = USER_AGENT };
    }
    return headers;
}

fn parseResponse(arena: Allocator, res: *Client.Response) !Result {
    var transfer_buffer: [64]u8 = undefined;
    const reader = res.reader(&transfer_buffer);

    var buffer: std.Io.Writer.Allocating = .init(arena);
    _ = reader.streamRemaining(&buffer.writer) catch |err| switch (err) {
        error.ReadFailed => return res.bodyErr().?,
        else => |e| return e,
    };

    const headers = try arena.dupe(u8, res.head.bytes);

    return .{
        .status = res.head.status,
        .headers = .init(headers),
        .body = buffer.written(),
    };
}
