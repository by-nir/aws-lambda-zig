# AWS Lambda Runtime for Zig

Write AWS Lambda functions in Zig.

- [x] Runtime API: _2018-06-01 (1.0.3)_
- [ ] Streaming
- [ ] Layers
- [ ] Extensions API: _2020-01-01 (1.0.1)_
- [ ] Telemetry API

### Benchmark
Using zig allows creating small and fast functions.

Running the simple _echo demo_ on _Arm (512MB)_:
- Cold start: ~10ms
- Invocation: ~1.5ms
- Max memory: 13 MB
- Function size: 2.0 MB
- Executable size: 10.1 MB

Usage
-----

### Setup
1. Add this package as a dependency to your project.
2. Import the `aws-lambda` module in your `build.zig` script. 

### Code

```zig
const lambda = @import("aws-lambda");

/// Provides a persistant GPA and an ephemeral per-event arena.
const Allocators = lambda.Allocators;

/// Metadata for processing the event (including env variables).
const Context = lambda.Context;

/// Logging scope for the handler function.
///
/// In release builds only _error_ level logs will be retained and sent to CloudWatch.
const log = lambda.log;

/// Entry point for the lambda runtime.
pub fn main() void {
    lambda.runHandler(handler);
}

/// Eeach event is processed separetly by this function.
fn handler(allocs: lambda.Allocators, context: lambda.Context, event: []const u8) anyerror![]const u8 {
    return "Hey there!";
}
```

### Distribute

1. Build for _Linux_ with `x86_64` or `aarch64` architectures.
2. Name the executable `bootstrap`.
3. Archive the executable into a **zip**.
4. Upload the archive to Lambda through the console, CLI, SAM or any CI solution.

Demos
-----

### Echo
Prints the provdedid payload.

```zig
zig build demo:echo --release
```

### Debug
Print the function metadata, env variables and the provided payload.

🛑 _May expose sensative data to the public._

```zig
zig build demo:debug --release
```

## Acknowledgment
- https://github.com/softprops/zig-lambda-runtime
- https://github.com/awslabs/aws-lambda-rust-runtime