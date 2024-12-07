const std = @import("std");

/// The runtime’s logging scope.
pub const runtime = std.log.scoped(.Runtime);

/// The handler’s logging scope.
///
/// In release mode only _error_ level is preserved, other levels are removed at compile time.
/// This behavior may be overriden at build.
pub const handler = std.log.scoped(.Handler);
