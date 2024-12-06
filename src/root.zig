const lambda = @import("lambda.zig");
pub const log = lambda.log_handler;
pub const Context = lambda.Context;
pub const Allocators = lambda.Allocators;

const serve = @import("runtime/serve.zig");
pub const Options = serve.ServerOptions;

const hdl = @import("runtime/handle.zig");
pub const Stream = hdl.Stream;
pub const handle = hdl.handleBuffered;
pub const handleStream = hdl.handleStreaming;

test {
    _ = @import("utils/Http.zig");
    _ = lambda;
    _ = @import("runtime/api.zig");
    _ = serve;
    _ = hdl;
}
