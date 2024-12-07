const serve = @import("runtime/serve.zig");
pub const Options = serve.ServerOptions;

const hdl = @import("runtime/handle.zig");
pub const Stream = hdl.Stream;
pub const handle = hdl.handleBuffered;
pub const handleStream = hdl.handleStreaming;

const ctx = @import("runtime/context.zig");
pub const Context = ctx.Context;

pub const log = @import("utils/log.zig").handler;

test {
    _ = @import("utils/Http.zig");
    _ = @import("runtime/api.zig");
    _ = ctx;
    _ = hdl;
    _ = serve;
}
