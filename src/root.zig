const lambda = @import("lambda.zig");
const server = @import("server.zig");

/// The handler’s logging scope.
pub const log = lambda.log_handler;

/// A persistant GPA and an invocation-scoped Arena.
pub const Allocators = lambda.Allocators;

/// Metadata for processing the event.
pub const Context = lambda.Context;

/// An interface for sending streaming response chunks.
pub const Channel = @import("Channel.zig");

/// The entry point for the AWS Lambda function.
///
/// Accepts a const reference to a handler function that will process each event separetly.
pub const serve = server.serveBuffer;

/// The entry point for the AWS Lambda streaming function.
///
/// Accepts a const reference to a streaming handler function that will process each event separetly.
pub const serveStream = server.serveStream;

test {
    _ = @import("api_runtime.zig");
    _ = @import("Client.zig");
    _ = @import("Runtime.zig");
    _ = lambda;
    _ = Channel;
    _ = server;
}
