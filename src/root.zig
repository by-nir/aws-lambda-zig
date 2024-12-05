const lambda = @import("lambda.zig");
pub const log = lambda.log_handler;
pub const Context = lambda.Context;
pub const Allocators = lambda.Allocators;

const server = @import("server.zig");
pub const Stream = server.Stream;
pub const serve = server.serveBuffered;
pub const serveStream = server.serveStreaming;

test {
    _ = @import("Http.zig");
    _ = @import("api_runtime.zig");
    _ = @import("Runtime.zig");
    _ = lambda;
    _ = server;
}
