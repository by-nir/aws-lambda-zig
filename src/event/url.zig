const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Scanner = std.json.Scanner;
const testing = std.testing;
const test_alloc = testing.allocator;
const json = @import("../utils/json.zig");
const KeyVal = @import("../utils/KeyVal.zig");
const hdl = @import("../runtime/handle.zig");

// https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html
// https://github.com/awslabs/aws-lambda-rust-runtime/blob/main/lambda-events/src/event/lambda_function_urls/mod.rs

const INTEGRATION_CONTENT_TYPE = "application/vnd.awslambda.http-integration-response";

pub const ResponseBody = union(enum) {
    textual: []const u8,
    binary: []const u8,
};

pub const Response = struct {
    /// The HTTP content type of the response.
    content_type: ?[]const u8 = null,
    /// The HTTP status code for the response.
    status_code: std.http.Status = .ok,
    /// A list of all cookies sent as part of the response.
    /// Lambda automatically interprets this and adds them as `set-cookie` headers in your HTTP response.
    /// Example:
    /// ```http
    /// cookie1=value1; Expires=21 Oct 2021 07:48 GMT
    /// ```
    cookies: []const []const u8 = &.{},
    /// The response’s headers. Lambda URLs **don’t support** headers with multiple values.
    ///
    /// To set the content type of the response, use the `content_type` field.
    /// To return cookies from your function, don't manually add `set-cookie` headers, instead set the `cookies` field.
    headers: []const KeyVal = &.{},
    /// The body of the response.
    body: ResponseBody = .{
        .textual = "",
    },

    /// A pre-encoded response for a HTTP 500 Internal Server Error.
    ///
    /// Usefaul for cases when encoding a dynamic response is impossible (e.g. can’t allocate).
    pub const internal_server_error = "{\"statusCode\":500,body:\"Internal Server Error\"}";

    pub fn encode(self: Response, gpa: Allocator) ![]const u8 {
        var buffer: std.Io.Writer.Allocating = .init(gpa);
        errdefer buffer.deinit();

        try buffer.writer.writeByte('{');
        try buffer.writer.print("\"statusCode\":{d}", .{@intFromEnum(self.status_code)});

        if (self.cookies.len > 0) {
            try buffer.writer.writeAll(",\"cookies\":[");
            for (self.cookies, 0..) |cookie, i| {
                if (i != 0) try buffer.writer.writeByte(',');
                try std.json.Stringify.encodeJsonString(cookie, .{}, &buffer.writer);
            }
            try buffer.writer.writeByte(']');
        }

        if (self.headers.len > 0 or self.content_type != null) {
            try buffer.writer.writeAll(",\"headers\":{");

            var has_ct = false;
            if (self.content_type) |ct| {
                try buffer.writer.writeAll("\"Content-Type\":");
                try std.json.Stringify.encodeJsonString(ct, .{}, &buffer.writer);
                has_ct = true;
            }

            for (self.headers, 0..) |header, i| {
                if (has_ct or i != 0) try buffer.writer.writeByte(',');
                try std.json.Stringify.encodeJsonString(header.key, .{}, &buffer.writer);
                try buffer.writer.writeByte(':');
                try std.json.Stringify.encodeJsonString(header.value, .{}, &buffer.writer);
            }

            try buffer.writer.writeByte('}');
        }

        switch (self.body) {
            .textual => |s| if (s.len > 0) {
                try buffer.writer.writeAll(",\"body\":");
                try std.json.Stringify.encodeJsonString(s, .{}, &buffer.writer);
            },
            .binary => |s| if (s.len > 0) {
                try buffer.writer.writeAll(",\"isBase64Encoded\":true");
                try buffer.writer.writeAll(",\"body\":\"");
                try std.base64.standard.Encoder.encodeWriter(&buffer.writer, s);
                try buffer.writer.writeByte('"');
            },
        }

        try buffer.writer.writeByte('}');
        return buffer.toOwnedSlice();
    }
};

test Response {
    const text_response = Response{
        .status_code = .created,
        .content_type = "application/json",
        .cookies = &.{
            "Cookie_1=Value1; Expires=21 Oct 2021 07:48 GMT",
            "Cookie_2=Value2; Max-Age=78000",
        },
        .headers = &.{
            .{ .key = "Foo-Header", .value = "Bar Value" },
            .{ .key = "Baz-Header", .value = "Qux Value" },
        },
        .body = .{
            .textual = "{\"message\":\"Hello, world!\"}",
        },
    };

    const text_encoded = try text_response.encode(test_alloc);
    defer test_alloc.free(text_encoded);

    try testing.expectEqualStrings("{" ++
        \\"statusCode":201,
    ++
        \\"cookies":["Cookie_1=Value1; Expires=21 Oct 2021 07:48 GMT","Cookie_2=Value2; Max-Age=78000"],
    ++
        \\"headers":{"Content-Type":"application/json","Foo-Header":"Bar Value","Baz-Header":"Qux Value"},
    ++
        \\"body":"{\"message\":\"Hello, world!\"}"
    ++ "}", text_encoded);

    const binary_response = Response{
        .body = .{ .binary = "foo108!" },
    };

    const binary_encoded = try binary_response.encode(test_alloc);
    defer test_alloc.free(binary_encoded);

    try testing.expectEqualStrings("{" ++
        \\"statusCode":200,
    ++
        \\"isBase64Encoded":true,
    ++
        \\"body":"Zm9vMTA4IQ=="
    ++ "}", binary_encoded);
}

/// Open an HTTP streaming response.
///
/// ```zig
/// try lambda.url.openStream(ctx, stream, .{
///     .status_code = .ok,
///     .content_type = "text/html; charset=utf-8",
///     .cookies = &.{ "cookie1=value1; Max-Age=86400; HttpOnly; Secure; SameSite=Lax" },
///     .headers = &.{ .{ .key = "Cache-Control", .value = "max-age=300, immutable" } },
///     .body = .{ .textual = "<h1>Incoming...</h1>" },
/// });
/// ```
pub fn openStream(ctx: hdl.Context, stream: hdl.Stream, response: Response) !*std.Io.Writer {
    // https://github.com/awslabs/aws-lambda-rust-runtime/blob/main/lambda-runtime/src/requests.rs
    // https://aws.amazon.com/blogs/compute/using-response-streaming-with-aws-lambda-web-adapter-to-optimize-performance
    const writer = try stream.openPrint(INTEGRATION_CONTENT_TYPE, "{f}", .{StreamingResponse{
        .arena = ctx.arena,
        .response = response,
    }});

    _ = try writer.splatByte('\x00', 8);
    try stream.publish();

    const body = switch (response.body) {
        inline else => |s| s,
    };

    if (body.len > 0) {
        try writer.writeAll(body);
        try stream.publish();
    }

    return writer;
}

const StreamingResponse = struct {
    arena: Allocator,
    response: Response,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        var response = self.response;
        response.body = .{ .textual = "" };

        const prelude = response.encode(self.arena) catch {
            return std.Io.Writer.Error.WriteFailed;
        };
        try writer.writeAll(prelude);
    }
};

pub const Request = struct {
    /// The request path. If the request URL is `https://{url-id}.lambda-url.{region}.on.aws/example/test/demo`,
    /// then the raw path value is `/example/test/demo`.
    raw_path: ?[]const u8 = null,
    /// The raw string containing the request’s query string parameters.
    /// Supported characters include `a-z`, `A-Z`, `0-9`, `.`, `_`, `-`, `%`, `&`, `=`, and `+`.
    raw_query: ?[]const u8 = null,
    /// A list of all cookies sent as part of the request.
    /// Each cookie is represented as a string in the format `CookieName=CookieValue`.
    cookies: []const KeyVal = &.{},
    /// The request’s headers.
    /// Headers with multiple values will concatenate them with a comma.
    headers: []const KeyVal = &.{},
    /// The request’s query parameters.
    /// Parameters with multiple values will concatenate them with a comma.
    query_parameters: []const KeyVal = &.{},
    /// The body of the request.
    /// If the content type of the request is binary, the body is base64-encoded.
    body: ?[]const u8 = null,
    /// `true` if the body is a binary payload and base64-encoded, `false` otherwise.
    body_is_base64: bool = false,
    /// An object that contains additional information about the request.
    request_context: RequestContext = .{},

    pub fn init(gpa: Allocator, event: []const u8) !Request {
        var scanner = Scanner.initCompleteInput(gpa, event);
        defer scanner.deinit();

        var request = Request{};
        errdefer request.deinit(gpa);

        var it = try json.ObjectIterator.init(gpa, &scanner);
        errdefer it.deinit();
        while (try it.next()) |key| {
            if (mem.eql(u8, "rawPath", key)) {
                request.raw_path = try json.nextStringOptional(&scanner, null);
            } else if (mem.eql(u8, "rawQueryString", key)) {
                request.raw_query = try json.nextStringOptional(&scanner, null);
            } else if (mem.eql(u8, "cookies", key)) {
                request.cookies = try json.nextKeyValList(gpa, &scanner, "=");
            } else if (mem.eql(u8, "headers", key)) {
                request.headers = try json.nextKeyValMap(gpa, &scanner);
            } else if (mem.eql(u8, "queryStringParameters", key)) {
                request.query_parameters = try json.nextKeyValMap(gpa, &scanner);
            } else if (mem.eql(u8, "body", key)) {
                request.body = try json.nextStringOptional(&scanner, gpa);
            } else if (mem.eql(u8, "isBase64Encoded", key)) {
                request.body_is_base64 = try json.nextBool(&scanner);
            } else if (mem.eql(u8, "requestContext", key)) {
                request.request_context = try RequestContext.init(gpa, &scanner);
            } else if (mem.eql(u8, "version", key)) {
                try json.nextStringEqualErr(&scanner, "2.0", error.UnsupportedEventVersion);
            } else if (mem.eql(u8, "routeKey", key)) {
                try json.nextStringEqualErr(&scanner, "$default", error.UnexpectedRouteKey);
            } else {
                try scanner.skipValue();
            }
        }

        try json.nextExpect(&scanner, .end_of_document);
        return request;
    }

    pub fn deinit(self: Request, gpa: Allocator) void {
        json.freeKeyValList(gpa, self.cookies);
        json.freeKeyValMap(gpa, self.headers);
        json.freeKeyValMap(gpa, self.query_parameters);
        if (self.body) |s| gpa.free(s);
        self.request_context.deinit(gpa);
    }
};

test Request {
    try testing.expectError(
        error.UnsupportedEventVersion,
        Request.init(test_alloc, "{\"version\": \"3.0\"}"),
    );

    try testing.expectError(
        error.UnexpectedRouteKey,
        Request.init(test_alloc, "{\"routeKey\": \"$foo\"}"),
    );

    const request = try Request.init(test_alloc,
        \\{
        \\  "version": "2.0",
        \\  "routeKey": "$default",
        \\  "rawPath": "/my/path",
        \\  "rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value",
        \\  "cookies": [
        \\    "cookey1=cooval1",
        \\    "cookey2=cooval2"
        \\  ],
        \\  "headers": {
        \\    "header1": "value1",
        \\    "header2": "value1,value2"
        \\  },
        \\  "queryStringParameters": {
        \\    "parameter1": "value1,value2",
        \\    "parameter2": "value"
        \\  },
        \\  "body": "Hello from \"foo\" client!",
        \\  "isBase64Encoded": false,
        \\  "requestContext": {
        \\    "timeEpoch": 1583348638390,
        \\    "authorizer": {
        \\      "iam": {
        \\        "userArn": "arn:aws:iam::111122223333:user/example-user"
        \\      }
        \\    },
        \\    "http": {
        \\      "path": "/my/path"
        \\    }
        \\  }
        \\}
    );
    defer request.deinit(test_alloc);

    try testing.expectEqualDeep(Request{
        .raw_path = "/my/path",
        .raw_query = "parameter1=value1&parameter1=value2&parameter2=value",
        .cookies = &.{
            .{ .key = "cookey1", .value = "cooval1" },
            .{ .key = "cookey2", .value = "cooval2" },
        },
        .headers = &.{
            .{ .key = "header1", .value = "value1" },
            .{ .key = "header2", .value = "value1,value2" },
        },
        .query_parameters = &.{
            .{ .key = "parameter1", .value = "value1,value2" },
            .{ .key = "parameter2", .value = "value" },
        },
        .body = "Hello from \"foo\" client!",
        .body_is_base64 = false,
        .request_context = RequestContext{
            .time_epoch = 1583348638390,
            .authorizer = .{
                .iam = .{
                    .user_arn = "arn:aws:iam::111122223333:user/example-user",
                },
            },
            .http = .{
                .path = "/my/path",
            },
        },
    }, request);
}

pub const RequestContext = struct {
    /// The AWS account ID of the function owner.
    account_id: ?[]const u8 = null,

    /// The ID of the function URL.
    api_id: ?[]const u8 = null,

    /// The domain name of the function URL.
    domain_name: ?[]const u8 = null,

    /// The domain prefix of the function URL.
    domain_prefix: ?[]const u8 = null,

    /// The ID of the invocation request.
    /// You can use this ID to trace invocation logs related to your function.
    request_id: ?[]const u8 = null,

    /// The timestamp of the request. For example, `07/Sep/2021:22:50:22 +0000`.
    time: ?[]const u8 = null,

    /// The timestamp of the request, in Unix epoch time.
    time_epoch: i64 = 0,

    /// An object that contains details about the HTTP request.
    http: RequestHttp = .{},

    /// An object that contains information about the caller identity, if the function URL uses the _AWS_IAM_ auth type.
    /// Otherwise, Lambda sets this to `.none`.
    authorizer: RequestAuthorizer = .none,

    fn init(gpa: Allocator, scanner: *Scanner) !RequestContext {
        var context = RequestContext{};

        var it = try json.ObjectIterator.init(gpa, scanner);
        errdefer it.deinit();
        while (try it.next()) |key| {
            if (mem.eql(u8, "accountId", key)) {
                context.account_id = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "apiId", key)) {
                context.api_id = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "domainName", key)) {
                context.domain_name = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "domainPrefix", key)) {
                context.domain_prefix = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "requestId", key)) {
                context.request_id = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "time", key)) {
                context.time = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "timeEpoch", key)) {
                context.time_epoch = try json.nextNumber(scanner, i64);
            } else if (mem.eql(u8, "http", key)) {
                context.http = try RequestHttp.init(gpa, scanner);
            } else if (mem.eql(u8, "authorizer", key)) {
                context.authorizer = try RequestAuthorizer.from(gpa, scanner);
            } else if (mem.eql(u8, "routeKey", key)) {
                try json.nextStringEqualErr(scanner, "$default", error.UnexpectedRouteKey);
            } else if (mem.eql(u8, "stage", key)) {
                try json.nextStringEqualErr(scanner, "$default", error.UnexpectedStage);
            } else {
                try scanner.skipValue();
            }
        }

        return context;
    }

    fn deinit(self: RequestContext, gpa: Allocator) void {
        self.http.deinit(gpa);
    }
};

test RequestContext {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "accountId": "123456789012",
        \\  "apiId": "<urlid>",
        \\  "authentication": null,
        \\  "domainName": "<url-id>.lambda-url.us-west-2.on.aws",
        \\  "domainPrefix": "<url-id>",
        \\  "requestId": "id",
        \\  "routeKey": "$default",
        \\  "stage": "$default",
        \\  "time": "12/Mar/2020:19:03:58 +0000",
        \\  "timeEpoch": 1583348638390,
        \\  "authorizer": {
        \\    "iam": {
        \\      "userArn": "arn:aws:iam::111122223333:user/example-user"
        \\    }
        \\  },
        \\  "http": {
        \\    "path": "/my/path"
        \\  }
        \\}
    );
    defer scanner.deinit();

    const context = try RequestContext.init(test_alloc, &scanner);
    defer context.deinit(test_alloc);

    try testing.expectEqualDeep(RequestContext{
        .account_id = "123456789012",
        .api_id = "<urlid>",
        .domain_name = "<url-id>.lambda-url.us-west-2.on.aws",
        .domain_prefix = "<url-id>",
        .request_id = "id",
        .time = "12/Mar/2020:19:03:58 +0000",
        .time_epoch = 1583348638390,
        .http = .{
            .path = "/my/path",
        },
        .authorizer = .{
            .iam = .{
                .user_arn = "arn:aws:iam::111122223333:user/example-user",
            },
        },
    }, context);
}

pub const RequestHttp = struct {
    /// The HTTP method used in this request.
    /// Valid values include `GET`, `POST`, `PUT`, `HEAD`, `OPTIONS`, `PATCH`, and `DELETE`.
    method: ?std.http.Method = null,

    /// The request path. If the request URL is `https://{url-id}.lambda-url.{region}.on.aws/example/test/demo`,
    /// then the raw path value is `/example/test/demo`.
    path: ?[]const u8 = null,

    /// The protocol of the request. For exmaple: `HTTP/1.1`.
    protocol: ?[]const u8 = null,

    /// The source IP address of the immediate TCP connection making the request.
    source_ip: ?[]const u8 = null,

    /// The `User-Agent` request header value.
    user_agent: ?[]const u8 = null,

    fn init(gpa: Allocator, scanner: *Scanner) !RequestHttp {
        var http = RequestHttp{};

        var it = try json.ObjectIterator.init(gpa, scanner);
        errdefer it.deinit();
        while (try it.next()) |key| {
            if (mem.eql(u8, "method", key)) {
                const str = try json.nextStringOptional(scanner, null) orelse continue;
                http.method = parseHttpMethod(str);
            } else if (mem.eql(u8, "path", key)) {
                http.path = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "protocol", key)) {
                http.protocol = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "sourceIp", key)) {
                http.source_ip = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "userAgent", key)) {
                http.user_agent = try json.nextStringOptional(scanner, gpa);
            } else {
                try scanner.skipValue();
            }
        }

        return http;
    }

    fn deinit(self: RequestHttp, gpa: Allocator) void {
        if (self.user_agent) |s| gpa.free(s);
    }
};

test RequestHttp {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "method": "POST",
        \\  "path": "/my/path",
        \\  "protocol": "HTTP/1.1",
        \\  "sourceIp": "123.123.123.123",
        \\  "userAgent": "agent \"foo\" bar"
        \\}
    );
    defer scanner.deinit();

    const http = try RequestHttp.init(test_alloc, &scanner);
    defer http.deinit(test_alloc);

    try testing.expectEqualDeep(RequestHttp{
        .method = .POST,
        .path = "/my/path",
        .protocol = "HTTP/1.1",
        .source_ip = "123.123.123.123",
        .user_agent = "agent \"foo\" bar",
    }, http);
}

pub const RequestAuthorizer = union(enum) {
    none: void,
    iam: RequestAuthorizerIam,

    fn from(gpa: Allocator, scanner: *Scanner) !RequestAuthorizer {
        switch (try scanner.peekNextTokenType()) {
            .null => return .none,
            .object_begin => {
                const u = try json.Union.begin(scanner);
                if (mem.eql(u8, "iam", u.key)) {
                    const auth = RequestAuthorizer{
                        .iam = try RequestAuthorizerIam.from(gpa, scanner),
                    };
                    try u.endErr(error.UnexpectedAuthorizer);
                    return auth;
                } else {
                    return error.UnexpectedAuthorizer;
                }
            },
            else => return json.inputError(),
        }
    }
};

test RequestAuthorizer {
    var scanner = Scanner.initCompleteInput(test_alloc, "null");
    defer scanner.deinit();
    try testing.expectEqual(RequestAuthorizer.none, try RequestAuthorizer.from(test_alloc, &scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "{\"foo\": \"bar\"}");
    try testing.expectError(error.UnexpectedAuthorizer, RequestAuthorizer.from(test_alloc, &scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "iam": { "userId": "AIDACOSFODNN7EXAMPLE2" }
        \\}
    );
    try testing.expectEqualDeep(
        RequestAuthorizer{
            .iam = .{ .user_id = "AIDACOSFODNN7EXAMPLE2" },
        },
        try RequestAuthorizer.from(test_alloc, &scanner),
    );

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "iam": { "userId": "AIDACOSFODNN7EXAMPLE2" },
        \\  "foo": "bar"
        \\}
    );
    try testing.expectError(error.UnexpectedAuthorizer, RequestAuthorizer.from(test_alloc, &scanner));
}

pub const RequestAuthorizerIam = struct {
    /// The access key of the caller identity.
    access_key: ?[]const u8 = null,

    /// The AWS account ID of the caller identity.
    account_id: ?[]const u8 = null,

    /// The ID (user ID) of the caller.
    caller_id: ?[]const u8 = null,

    /// The principal org ID associated with the caller identity.
    principal_org_id: ?[]const u8 = null,

    /// The user Amazon Resource Name (ARN) of the caller identity.
    user_arn: ?[]const u8 = null,

    /// The user ID of the caller identity.
    user_id: ?[]const u8 = null,

    fn from(gpa: Allocator, scanner: *Scanner) !RequestAuthorizerIam {
        var iam = RequestAuthorizerIam{};

        var it = try json.ObjectIterator.init(gpa, scanner);
        errdefer it.deinit();
        while (try it.next()) |key| {
            if (mem.eql(u8, "accessKey", key)) {
                iam.access_key = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "accountId", key)) {
                iam.account_id = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "callerId", key)) {
                iam.caller_id = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "principalOrgId", key)) {
                iam.principal_org_id = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "userArn", key)) {
                iam.user_arn = try json.nextStringOptional(scanner, null);
            } else if (mem.eql(u8, "userId", key)) {
                iam.user_id = try json.nextStringOptional(scanner, null);
            } else {
                try scanner.skipValue();
            }
        }

        return iam;
    }
};

test RequestAuthorizerIam {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "accessKey": "AKIAIOSFODNN7EXAMPLE",
        \\  "accountId": "111122223333",
        \\  "callerId": "AIDACKCEVSQ6C2EXAMPLE",
        \\  "cognitoIdentity": null,
        \\  "principalOrgId": "AIDACKCEVSQORGEXAMPLE",
        \\  "userArn": "arn:aws:iam::111122223333:user/example-user",
        \\  "userId": "AIDACOSFODNN7EXAMPLE2"
        \\}
    );
    defer scanner.deinit();

    try testing.expectEqualDeep(
        RequestAuthorizerIam{
            .access_key = "AKIAIOSFODNN7EXAMPLE",
            .account_id = "111122223333",
            .caller_id = "AIDACKCEVSQ6C2EXAMPLE",
            .principal_org_id = "AIDACKCEVSQORGEXAMPLE",
            .user_arn = "arn:aws:iam::111122223333:user/example-user",
            .user_id = "AIDACOSFODNN7EXAMPLE2",
        },
        try RequestAuthorizerIam.from(test_alloc, &scanner),
    );
}

fn parseHttpMethod(str: []const u8) std.http.Method {
    inline for (comptime std.enums.values(std.http.Method)) |tag| {
        if (std.mem.eql(u8, @tagName(tag), str)) return tag;
    } else {
        unreachable;
    }
}
