# AWS Lambda Runtime for Zig

Write AWS Lambda functions in Zig.

- [x] Runtime API
- [ ] Extensions API
- [ ] Telemetry API
- [x] CloudWatch & X-Ray integration
- [ ] Response Streaming
- [ ] Layers

### Benchmark
Using zig allows creating small and fast functions.

Running a basic _Echo_ demo on _arm64 (512 MB)_:
- Cold init duration: ~10ms
- Invocation duration: ~1.5ms
- Max memory: 14 MB
- Function size: 1.7 MB
- Executable size: 8.1 MB

Usage
-----

### Setup
1. Add this package as a dependency to your project.
2. Import the `aws-lambda` module in your `build.zig` script. 

### Minimal Code

```zig
const lambda = @import("aws-lambda");

/// The handler’s logging scope.
/// In release builds only _error_ level logs are sent to CloudWatch.
const log = lambda.log;

/// Entry point for the lambda runtime.
pub fn main() void {
    lambda.serve(handler);
}

/// Eeach event is processed separetly by this function.
/// The function must have the following signature:
fn handler(
    allocs: lambda.Allocators,      // Persistant GPA & invocation-scoped Arena.
    context: *const lambda.Context, // Function metadata (including env).
    event: []const u8,              // JSON payload.
) ![]const u8 {
    return "Hey there!";
}
```

### Distribute

1. Build for **Linux** with `aarch64` (`neoverse_n1`+`neon`) or `x86_64` (+`avx2`) architecture.
2. Name the executable `bootstrap`.
3. Archive the executable into a **zip**.
4. Upload the archive to Lambda (using _Amazon Linux 2023_ or another **OS-only runtime**). This shouls work through the console, CLI, SAM or anyCI solution.

Demos
-----

### Echo
Returns the provided payload.

```zig
zig build demo:echo --release
```

### Debug
Returns the function’s metadata, environment variables and the provided payload.

🛑 _May expose sensative data to the public._

```zig
zig build demo:debug --release
```

### Fail: Handler Error
Always returns an error; the runtime logs the error to _CloudWatch_.

```zig
zig build demo:fail --release
```

### Fail: Oversized Output
Returns an output larger than the Lambda limit; the runtime logs an error to _CloudWatch_.

```zig
zig build demo:oversize --release
```

## Acknowledgment
- https://github.com/softprops/zig-lambda-runtime
- https://github.com/awslabs/aws-lambda-rust-runtime