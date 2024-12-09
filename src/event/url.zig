const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Scanner = std.json.Scanner;
const testing = std.testing;
const test_alloc = testing.allocator;
const json = @import("../utils/json.zig");
const KeyVal = @import("../utils/KeyVal.zig");

// https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html
// https://github.com/awslabs/aws-lambda-rust-runtime/blob/main/lambda-events/src/event/lambda_function_urls/mod.rs

pub const ResponseBody = union(enum) {
    textual: []const u8,
    binary: []const u8,
};

pub const Response = struct {
    /// The HTTP status code for the response.
    status_code: std.http.Status = .ok,
    /// A list of all cookies sent as part of the response.
    /// Lambda automatically interprets this and adds them as `set-cookie` headers in your HTTP response.
    /// Example:
    /// ```http
    /// cookie1=value1; Expires=21 Oct 2021 07:48 GMT
    /// ```
    cookies: []const []const u8 = &.{},
    /// The response’s headers. Headers with multiple values should concatenate them with a comma.
    ///
    /// To return cookies from your function, don't manually add `set-cookie` headers, instead set the `cookies` field.
    headers: []const KeyVal = &.{},
    /// The body of the response.
    body: ResponseBody = .{ .textual = "" },

    pub fn encode(self: Response, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();
        try writer.writeByte('{');

        try writer.print("\"statusCode\":{d},", .{@intFromEnum(self.status_code)});

        if (self.cookies.len > 0) {
            try writer.writeAll("\"cookies\":[");
            for (self.cookies, 0..) |cookie, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.encodeJsonString(cookie, .{}, writer);
            }
            try writer.writeAll("],");
        }

        if (self.headers.len > 0) {
            try writer.writeAll("\"headers\":{");
            for (self.headers, 0..) |header, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.encodeJsonString(header.key, .{}, writer);
                try writer.writeByte(':');
                try std.json.encodeJsonString(header.value, .{}, writer);
            }
            try writer.writeAll("},");
        }

        switch (self.body) {
            .textual => |s| {
                try writer.writeAll("\"body\":");
                try std.json.encodeJsonString(s, .{}, writer);
            },
            .binary => |s| {
                try writer.writeAll("\"isBase64Encoded\":true,");
                try writer.writeAll("\"body\":\"");
                try std.base64.standard.Encoder.encodeWriter(writer, s);
                try writer.writeByte('"');
            },
        }

        try writer.writeByte('}');
        return buffer.toOwnedSlice();
    }
};

test Response {
    const text_response = Response{
        .status_code = .created,
        .cookies = &.{
            "Cookie_1=Value1; Expires=21 Oct 2021 07:48 GMT",
            "Cookie_2=Value2; Max-Age=78000",
        },
        .headers = &.{
            .{ .key = "Content-Type", .value = "application/json" },
            .{ .key = "My-Custom-Header", .value = "Custom Value" },
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
        \\"headers":{"Content-Type":"application/json","My-Custom-Header":"Custom Value"},
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

    pub fn init(allocator: Allocator, source: []const u8) !Request {
        var scanner = Scanner.initCompleteInput(allocator, source);
        defer scanner.deinit();

        var request = Request{};
        errdefer request.deinit(allocator);

        var it = try json.ObjectIterator.begin(&scanner);
        while (try it.next()) |key| {
            if (mem.eql(u8, "rawPath", key)) {
                request.raw_path = try json.nextStringOptional(&scanner);
            } else if (mem.eql(u8, "rawQueryString", key)) {
                request.raw_query = try json.nextStringOptional(&scanner);
            } else if (mem.eql(u8, "cookies", key)) {
                request.cookies = try json.nextKeyValList(allocator, &scanner, "=");
            } else if (mem.eql(u8, "headers", key)) {
                request.headers = try json.nextKeyValMap(allocator, &scanner);
            } else if (mem.eql(u8, "queryStringParameters", key)) {
                request.query_parameters = try json.nextKeyValMap(allocator, &scanner);
            } else if (mem.eql(u8, "body", key)) {
                request.body = try json.nextStringOptional(&scanner);
            } else if (mem.eql(u8, "isBase64Encoded", key)) {
                request.body_is_base64 = try json.nextBool(&scanner);
            } else if (mem.eql(u8, "requestContext", key)) {
                request.request_context = try RequestContext.from(&scanner);
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

    pub fn deinit(self: Request, allocator: Allocator) void {
        allocator.free(self.cookies);
        allocator.free(self.headers);
        allocator.free(self.query_parameters);
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
        \\  "body": "Hello from client!",
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
        .body = "Hello from client!",
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

    fn from(scanner: *Scanner) !RequestContext {
        var context = RequestContext{};

        var it = try json.ObjectIterator.begin(scanner);
        while (try it.next()) |key| {
            if (mem.eql(u8, "accountId", key)) {
                context.account_id = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "apiId", key)) {
                context.api_id = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "domainName", key)) {
                context.domain_name = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "domainPrefix", key)) {
                context.domain_prefix = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "requestId", key)) {
                context.request_id = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "time", key)) {
                context.time = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "timeEpoch", key)) {
                context.time_epoch = try json.nextNumber(scanner, i64);
            } else if (mem.eql(u8, "http", key)) {
                context.http = try RequestHttp.from(scanner);
            } else if (mem.eql(u8, "authorizer", key)) {
                context.authorizer = try RequestAuthorizer.from(scanner);
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

    try testing.expectEqualDeep(
        RequestContext{
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
        },
        try RequestContext.from(&scanner),
    );
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

    fn from(scanner: *Scanner) !RequestHttp {
        var http = RequestHttp{};

        var it = try json.ObjectIterator.begin(scanner);
        while (try it.next()) |key| {
            if (mem.eql(u8, "method", key)) {
                const str = try json.nextStringOptional(scanner) orelse continue;
                http.method = @enumFromInt(std.http.Method.parse(str));
            } else if (mem.eql(u8, "path", key)) {
                http.path = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "protocol", key)) {
                http.protocol = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "sourceIp", key)) {
                http.source_ip = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "userAgent", key)) {
                http.user_agent = try json.nextStringOptional(scanner);
            } else {
                try scanner.skipValue();
            }
        }

        return http;
    }
};

test RequestHttp {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "method": "POST",
        \\  "path": "/my/path",
        \\  "protocol": "HTTP/1.1",
        \\  "sourceIp": "123.123.123.123",
        \\  "userAgent": "agent"
        \\}
    );
    defer scanner.deinit();

    try testing.expectEqualDeep(
        RequestHttp{
            .method = .POST,
            .path = "/my/path",
            .protocol = "HTTP/1.1",
            .source_ip = "123.123.123.123",
            .user_agent = "agent",
        },
        try RequestHttp.from(&scanner),
    );
}

pub const RequestAuthorizer = union(enum) {
    none: void,
    iam: RequestAuthorizerIam,

    fn from(scanner: *Scanner) !RequestAuthorizer {
        switch (try scanner.peekNextTokenType()) {
            .null => return .none,
            .object_begin => {
                const u = try json.Union.begin(scanner);
                if (mem.eql(u8, "iam", u.key)) {
                    const auth = RequestAuthorizer{
                        .iam = try RequestAuthorizerIam.from(scanner),
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
    try testing.expectEqual(RequestAuthorizer.none, try RequestAuthorizer.from(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "{\"foo\": \"bar\"}");
    try testing.expectError(error.UnexpectedAuthorizer, RequestAuthorizer.from(&scanner));

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
        try RequestAuthorizer.from(&scanner),
    );

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "iam": { "userId": "AIDACOSFODNN7EXAMPLE2" },
        \\  "foo": "bar"
        \\}
    );
    try testing.expectError(error.UnexpectedAuthorizer, RequestAuthorizer.from(&scanner));
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

    fn from(scanner: *Scanner) !RequestAuthorizerIam {
        var iam = RequestAuthorizerIam{};

        var it = try json.ObjectIterator.begin(scanner);
        while (try it.next()) |key| {
            if (mem.eql(u8, "accessKey", key)) {
                iam.access_key = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "accountId", key)) {
                iam.account_id = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "callerId", key)) {
                iam.caller_id = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "principalOrgId", key)) {
                iam.principal_org_id = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "userArn", key)) {
                iam.user_arn = try json.nextStringOptional(scanner);
            } else if (mem.eql(u8, "userId", key)) {
                iam.user_id = try json.nextStringOptional(scanner);
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
        try RequestAuthorizerIam.from(&scanner),
    );
}