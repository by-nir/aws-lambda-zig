//! Use Lambda URLs to serve dynamic web pages.
//!
//! ⚠️ This is not a production-ready web server, don’t use it in production!
//!
//! 👉 Be sure to configure the Lambda function with URL enabled and BUFFERED
//! invoke mode.
const std = @import("std");
const mem = std.mem;
const lambda = @import("aws-lambda");

const html_type = "text/html; charset=utf-8";
const global_nav = "<nav><a href=\"/\">← Homepage</a></nav>\n\n";

pub fn main(init: std.process.Init) void {
    lambda.handle(init, handler, .{});
}

fn handler(ctx: lambda.Context, event: []const u8) ![]const u8 {
    // Decode the Lambda URLs event.
    // We pass an arena allocator, so we don’t need to deinit.
    const request = try lambda.url.parseRequest(ctx.arena, event);

    // Use the router the serve dynamic content based on the event’s request.
    // If rendering the response fails, we instead return an error page.
    return router(ctx, request) catch |err| {
        // ctx.forceTerminateAfterResponse();
        // 👆 Uncomment the above line if you assume the function won’t behave
        // as expected in the following invocation. The Lambda execution environment
        // will terminate the function instance AFTER rendering the error page.

        // Log the error to CloudWatch:
        lambda.log.err("Web server failed; raw path: `{s}`.", .{
            request.raw_path orelse "",
        });

        // Render a custom error page:
        return internalErrorPage(ctx, err)
        // In case we can’t render the error page either (eg. out of memory),
        // the last resort is to return a pre-encoded static response:
        catch lambda.url.Response.internal_server_error;
    };
}

/// Returns a different response based on the path.
/// Each page will use `lambda.url.encodeResponse()` to compose its own response.
fn router(ctx: lambda.Context, req: lambda.url.Request) ![]const u8 {
    const path = req.request_context.http.path orelse "/";
    if (mem.eql(u8, "/", path)) {
        return homePage(ctx);
    } else if (mem.eql(u8, "/ip", path)) {
        return ipAddrPage(ctx, req);
    } else if (mem.eql(u8, "/hello", path)) {
        return greetPage(ctx, req);
    } else if (mem.eql(u8, "/cookiejar", path)) {
        return storagePage(ctx, req);
    } else if (mem.eql(u8, "/53cr37", path)) {
        return downloadPage(ctx, req);
    } else if (mem.eql(u8, "/crash", path)) {
        return crashPage();
    } else {
        return errorPage(ctx, path);
    }
}

/// Static HTML response containing links to other pages.
fn homePage(ctx: lambda.Context) ![]const u8 {
    return lambda.url.encodeResponse(ctx.arena, .{
        .content_type = "text/html; charset=utf-8",
        .headers = &.{
            // This page is static, so we can ask for it to be cached for a while.
            // Remove or comment-out this line if you want to see the page
            // update immediately.
            .{ .key = "Cache-Control", .value = "max-age=300, immutable" },
        },
        .body = .{ .textual =
        \\<h1>Lambda URLs ⚡️ Zig Runtime</h1>
        \\<p>Welcome to the demo web page!</p>
        \\
        \\<ul>
        \\  <li>🏠 <a href="/ip">What’s my IP address?</a></li>
        \\  <li>👋 <a href="/hello?name=stranger">Greatings, stranger</a></li>
        \\  <li>🍪 <a href="/cookiejar">Storage</a></li>
        \\  <li>🔑 <a href="/53cr37" download="53cr37.txt">53cr37.txt</a></li>
        \\  <li>🕵️‍♂️ <a href="/oops">Dude, where is my web page?</a></li>
        \\  <li>🧨 <a href="/crash">500</a></li>
        \\</ul>
        },
    });
}

/// The `url.Request` contains both the HTTP request and additional AWS metadata.
fn ipAddrPage(ctx: lambda.Context, req: lambda.url.Request) ![]const u8 {
    // Generate dynamic HTML content, note the usage of an arena allocator.
    var html: std.Io.Writer.Allocating = .init(ctx.arena);

    try html.writer.writeAll(global_nav);
    if (req.request_context.http.source_ip) |addr| {
        try html.writer.print("<p>Your IP address is: <mark>{s}</mark></p>", .{addr});
    } else {
        try html.writer.writeAll("<p>Sorry, I don’t know your IP address.</p>");
    }

    return lambda.url.encodeResponse(ctx.arena, .{
        .content_type = html_type,
        .body = .{ .textual = try html.toOwnedSlice() },
    });
}

/// Use a parsed query parameter provided by the decoded request to greet the user.
fn greetPage(ctx: lambda.Context, req: lambda.url.Request) ![]const u8 {
    var html: std.Io.Writer.Allocating = .init(ctx.arena);

    try html.writer.writeAll(global_nav);

    const name = blk: {
        // Is the `name` parameter present in the query?
        for (req.query_parameters) |param| {
            if (!mem.eql(u8, "name", param.key)) continue;
            if (param.value.len > 0) break :blk param.value else break;
        }

        break :blk "world"; // Default value
    };
    try html.writer.print("<h1>Hello, {s}!</h1>", .{name});

    try html.writer.writeAll("\n\n");
    try html.writer.writeAll(
        \\<p>
        \\  <em>Hint:</em> Change the <code>name</code> parameter in the URL...
        \\</p>
    );

    return lambda.url.encodeResponse(ctx.arena, .{
        .content_type = html_type,
        .body = .{ .textual = try html.toOwnedSlice() },
    });
}

/// Generate dynamic HTML form that mutates the `store` cookie.
fn storagePage(ctx: lambda.Context, req: lambda.url.Request) ![]const u8 {
    const max_len = 64;
    var buffer: [128]u8 = undefined;
    var value: []const u8 = undefined;
    var set_cookies: []const []const u8 = &.{};
    eval: {
        for (req.query_parameters) |param| {
            // Is the `store` parameter present in the query?
            if (!mem.eql(u8, "store", param.key)) continue;
            value = switch (param.value.len) {
                0 => break, // Use default value
                1...max_len => param.value, // Valid value
                else => param.value[0..max_len], // Truncate value
            };
            break;
        } else for (req.cookies) |cookie| {
            // Is the `store` cookie present?
            if (!mem.eql(u8, "store", cookie.key)) continue;
            const len = try std.base64.standard.Decoder.calcSizeForSlice(cookie.value);
            try std.base64.standard.Decoder.decode(buffer[0..len], cookie.value);
            value = buffer[0..len];
            break :eval; // No need to send the unmodified cookie to the client
        } else {
            value = "crumbs"; // Default value
        }

        // Encode the cookie value
        var new_cookie: std.Io.Writer.Allocating = .init(ctx.arena);
        errdefer new_cookie.deinit();
        try new_cookie.writer.writeAll("store=");
        try std.base64.standard.Encoder.encodeWriter(&new_cookie.writer, value);
        try new_cookie.writer.writeAll("; Path=/cookiejar; Max-Age=432000; HttpOnly; Secure; SameSite=Lax");
        set_cookies = &.{try new_cookie.toOwnedSlice()};
    }

    // Render a form to display and update the stored value.
    var html: std.Io.Writer.Allocating = .init(ctx.arena);
    try html.writer.writeAll(global_nav);
    try html.writer.print(
        \\<form>
        \\  <label for="store">Stored value:</label>
        \\  <input type="text" id="store" name="store" value="{s}" minlength="1" maxlength="{d}" required />
        \\  <input type="submit" value="Save">
        \\</form>
    , .{ value, max_len });

    return lambda.url.encodeResponse(ctx.arena, .{
        .cookies = set_cookies,
        .content_type = html_type,
        .body = .{ .textual = try html.toOwnedSlice() },
    });
}

/// Generate a text file with the request’s timestamp.
fn downloadPage(ctx: lambda.Context, req: lambda.url.Request) ![]const u8 {
    return lambda.url.encodeResponse(ctx.arena, .{
        // We respond with plain text instead of HTML like in the other pages.
        .content_type = "text/plain; charset=utf-8",

        // Since we are generating a downloadable file we use a `.binary` body
        // instead of `.textual`.
        .body = .{ .binary = req.request_context.time.? },
    });
}

/// Render a custom error page for the given path.
fn errorPage(ctx: lambda.Context, path: []const u8) ![]const u8 {
    const html = try std.fmt.allocPrint(
        ctx.arena,
        global_nav ++
            \\<h1>🥸 Oops...</h1>
            \\<p>Sorry, the page <code>{s}</code> is not here.</p>
        ,
        .{path},
    );

    return lambda.url.encodeResponse(ctx.arena, .{
        .status_code = .not_found, // HTTP 404
        .content_type = html_type,
        .body = .{ .textual = html },
    });
}

/// This page will always crash, the `handler` should catch the error and return
/// a custom error page.
fn crashPage() ![]const u8 {
    return error.RandomServerCrash;
}

/// Render a custom error page for the given error.
fn internalErrorPage(ctx: lambda.Context, err: anyerror) ![]const u8 {
    const html = try std.fmt.allocPrint(
        ctx.arena,
        global_nav ++
            \\<h1>💥 BOOM!</h1>
            \\<p>You broke the server: <code>{s}</code>.</p>
        ,
        .{@errorName(err)},
    );

    return lambda.url.encodeResponse(ctx.arena, .{
        .status_code = .internal_server_error, // HTTP 500
        .content_type = html_type,
        .body = .{ .textual = html },
    });
}
