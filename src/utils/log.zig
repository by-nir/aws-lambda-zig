const std = @import("std");

/// The runtime’s logging scope.
pub const runtime = std.log.scoped(.Runtime);

/// The handler’s logging scope.
///
/// In release mode, only the _error_ level is preserved; other levels are
/// removed at compile time.
/// This behavior may be overridden at build time.
pub const handler = std.log.scoped(.Handler);
