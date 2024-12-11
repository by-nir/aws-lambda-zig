const hdl = @import("runtime/handle.zig");
pub const Stream = hdl.Stream;
pub const Options = hdl.Options;
pub const Context = hdl.Context;
pub const handle = hdl.handleSync;
pub const handleAsync = hdl.handleAsync;
pub const handleStream = hdl.handleStreaming;

pub const KeyVal = @import("utils/KeyVal.zig");
pub const log = @import("utils/log.zig").handler;

// Events
pub const url = @import("event/url.zig");

test {
    _ = KeyVal;
    _ = @import("utils/json.zig");
    _ = @import("utils/Http.zig");
    _ = @import("runtime/api.zig");
    _ = @import("runtime/serve.zig");
    _ = @import("runtime/context.zig");
    _ = hdl;
    _ = url;
}
