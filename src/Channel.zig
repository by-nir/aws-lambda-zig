//! An interface for sending streaming response chunks.

pub const Error = error{ NotOpen, RuntimeFail };

const Self = @This();
pub const VTable = struct {
    open: *const fn (ctx: *anyopaque, content_type: []const u8) Error!void,
    write: *const fn (ctx: *anyopaque, payload: []const u8) Error!void,
    close: *const fn (ctx: *anyopaque) Error!void,
    fail: *const fn (ctx: *anyopaque, err: anyerror, message: []const u8) Error!void,
};

ctx: *anyopaque,
vtable: *const VTable,

/// Start the response stream of a given content type.
///
/// Calling open again after it has already been called is a non-op.
pub fn open(self: Self, content_type: []const u8) Error!void {
    try self.vtable.open(self.ctx, content_type);
}

/// Append a chunk to the response stream.
///
/// If an error occurs, the stream is closed and the handler should return as soon as possible.
pub fn write(self: Self, payload: []const u8) Error!void {
    try self.vtable.write(self.ctx, payload);
}

/// **Optional.** End the response stream and proceed to do other work in the handler.
///
/// If an error occurs, the stream is closed and the handler should return as soon as possible.
pub fn close(self: Self) Error!void {
    try self.vtable.close(self.ctx);
}

/// End the response stream with a **client-transmitted** error.
///
/// If an error occurs, the stream is closed and the handler should return as soon as possible.
pub fn fail(self: Self, err: anyerror, message: []const u8) Error!void {
    try self.vtable.fail(self.ctx, err, message);
}
