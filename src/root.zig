const lambda = @import("lambda.zig");
const Runtime = @import("Runtime.zig");
const server = @import("server.zig");

/// The handler’s logging scope.
pub const log = lambda.log_handler;

/// A persistant GPA and an invocation-scoped Arena.
pub const Allocators = lambda.Allocators;

/// Metadata for processing the event.
pub const Context = lambda.Context;

/// The entry point for the AWS Lambda function.
///
/// Accepts a const reference to a handler function that will process each event separetly.
pub const serve = server.runBuffer;

test {
    _ = @import("api_runtime.zig");
    _ = @import("Fetcher.zig");
    _ = lambda;
    _ = Runtime;
    _ = server;
}
