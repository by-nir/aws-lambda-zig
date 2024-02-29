const handle = @import("handle.zig");
const lambda = @import("lambda.zig");

/// The entry point for the AWS Lambda function.
///
/// Accepts a const reference to a handler function that will process eeach event separetly.
pub const runHandler = handle.run;

/// Provides a persistant GPA and an ephemeral per-event arena.
pub const Allocators = handle.Allocators;

/// Metadata for processing the event.
pub const Context = lambda.Context;

/// The handler’s logging scope.
pub const log = lambda.log_handler;

test {
    _ = handle;
    _ = lambda;
    _ = @import("Fetcher.zig");
    _ = @import("api_runtime.zig");
}
