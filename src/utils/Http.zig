//! A simple HTTP client shared between the APIs.
const std = @import("std");
const testing = std.testing;
const Client = std.http.Client;
const Allocator = std.mem.Allocator;

pub const Header = std.http.Header;
pub const Request = Client.Request;
pub const HeaderIterator = std.http.HeaderIterator;

const Self = @This();
const MAX_HEAD_BUFFER = 16 * 1024;
const MAX_BODY_BUFFER = 2 * 1024 * 1024;
const USER_AGENT = "aws-lambda-zig/0.0.0 (zig@" ++ @import("builtin").zig_version_string ++ ")";

var response_headers: [MAX_HEAD_BUFFER]u8 = undefined;

client: Client,
uri: std.Uri,

pub fn init(gpa: Allocator, origin: []const u8) !Self {
    const idx = std.mem.indexOfScalar(u8, origin, ':');
    const uri = std.Uri{
        .path = .{ .percent_encoded = "" },
        .scheme = "http",
        .host = .{ .raw = if (idx) |i| origin[0..i] else origin },
        .port = if (idx) |i|
            try std.fmt.parseUnsigned(u16, origin[i + 1 .. origin.len], 10)
        else
            null,
    };

    return .{
        .client = Client{ .allocator = gpa },
        .uri = uri,
    };
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

// Based on std.Http.Client.fetch
pub fn send(self: *Self, arena: Allocator, path: []const u8, payload: ?[]const u8, options: Options) !Result {
    const uri = self.uriFor(path);
    const method: std.http.Method = if (payload == null) .GET else .POST;
    var req = try self.client.open(method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .server_header_buffer = &response_headers,
        .headers = prepareHeaders(options.request),
        .extra_headers = options.headers orelse &.{},
    });
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
    }
    try req.send();

    if (payload) |p| {
        try req.writeAll(p);
    }

    try req.finish();
    return respond(&req, arena);
}

// Based on std.Http.Client.send
pub fn streamOpen(
    self: *Self,
    path: []const u8,
    options: Options,
    comptime raw_prelude: []const u8,
    args: anytype,
) !Request {
    const uri = self.uriFor(path);
    var req = try self.client.open(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .server_header_buffer = &response_headers,
        .headers = prepareHeaders(options.request),
        .extra_headers = options.headers orelse &.{},
    });
    errdefer req.deinit();

    req.transfer_encoding = .chunked;

    if (!req.method.requestHasBody() and req.transfer_encoding != .none)
        return error.UnsupportedTransferEncoding;

    const connection = req.connection.?;
    const w = connection.writer();

    try req.method.write(w);
    try w.writeByte(' ');

    if (req.method == .CONNECT) {
        try req.uri.writeToStream(.{ .authority = true }, w);
    } else {
        try req.uri.writeToStream(.{
            .scheme = connection.proxied,
            .authentication = connection.proxied,
            .authority = connection.proxied,
            .path = true,
            .query = true,
        }, w);
    }
    try w.writeByte(' ');
    try w.writeAll(@tagName(req.version));
    try w.writeAll("\r\n");

    if (try emitOverridableHeader("host: ", req.headers.host, w)) {
        try w.writeAll("host: ");
        try req.uri.writeToStream(.{ .authority = true }, w);
        try w.writeAll("\r\n");
    }

    if (try emitOverridableHeader("authorization: ", req.headers.authorization, w)) {
        if (req.uri.user != null or req.uri.password != null) {
            try w.writeAll("authorization: ");
            const authorization = try connection.allocWriteBuffer(
                @intCast(Client.basic_authorization.valueLengthFromUri(req.uri)),
            );
            std.debug.assert(Client.basic_authorization.value(req.uri, authorization).len == authorization.len);
            try w.writeAll("\r\n");
        }
    }

    if (try emitOverridableHeader("user-agent: ", req.headers.user_agent, w)) {
        try w.writeAll(USER_AGENT);
        try w.writeAll("\r\n");
    }

    if (try emitOverridableHeader("connection: ", req.headers.connection, w)) {
        if (req.keep_alive) {
            try w.writeAll("connection: keep-alive\r\n");
        } else {
            try w.writeAll("connection: close\r\n");
        }
    }

    if (try emitOverridableHeader("accept-encoding: ", req.headers.accept_encoding, w)) {
        // https://github.com/ziglang/zig/issues/18937
        //try w.writeAll("accept-encoding: gzip, deflate, zstd\r\n");
        try w.writeAll("accept-encoding: gzip, deflate\r\n");
    }

    try w.writeAll("transfer-encoding: chunked\r\n");
    _ = try emitOverridableHeader("content-type: ", req.headers.content_type, w);

    for (req.extra_headers) |header| {
        std.debug.assert(header.name.len != 0);
        try w.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    if (connection.proxied) proxy: {
        const proxy = switch (connection.protocol) {
            .plain => req.client.http_proxy,
            .tls => req.client.https_proxy,
        } orelse break :proxy;

        const authorization = proxy.authorization orelse break :proxy;
        try w.writeAll("proxy-authorization: ");
        try w.writeAll(authorization);
        try w.writeAll("\r\n");
    }

    try w.writeAll("\r\n");
    if (raw_prelude.len > 0) {
        try req.connection.?.writer().print(raw_prelude, args);
    }

    try connection.flush();
    return req;
}

pub fn streamClose(arena: Allocator, req: *Request, trailer: ?[]const Header) !Result {
    const connection = req.connection.?;
    defer {
        connection.closing = true;
        req.client.connection_pool.release(req.client.allocator, connection);
    }

    // Close with trailer
    if (trailer) |t| if (t.len > 0) {
        var w = connection.writer();
        try w.writeAll("0\r\n");

        for (t) |header| {
            std.debug.assert(header.name.len != 0);
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        try w.writeAll("\r\n");
        try connection.flush();
        return respond(req, arena);
    };

    // Close without trailer
    try req.finish();
    return respond(req, arena);
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

// std.Http.Client.emitOverridableHeader
fn emitOverridableHeader(prefix: []const u8, v: Client.Request.Headers.Value, w: anytype) !bool {
    switch (v) {
        .default => return true,
        .omit => return false,
        .override => |x| {
            try w.writeAll(prefix);
            try w.writeAll(x);
            try w.writeAll("\r\n");
            return false;
        },
    }
}

fn respond(req: *Request, arena: Allocator) !Result {
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
