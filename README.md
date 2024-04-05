# AWS Lambda Runtime for Zig
![Zig v0.12 (master)](https://img.shields.io/badge/Zig-v0.12_(master)-black?logo=zig&logoColor=F7A41D)
[![MIT License](https://img.shields.io/github/license/by-nir/aws-lambda-zig)](https://github.com/by-nir/aws-lambda-zig/LICENSE)

Write _AWS Lambda_ functions in the Zig programming language to achieve blazing fast invocations and cold starts!

### Features

- [x] Runtime API
- [ ] Extensions API
- [ ] Telemetry API
- [x] CloudWatch & X-Ray integration
- [x] Response streaming
- [ ] Life-cycle hooks
- [ ] Layers
- [ ] Structured events
- [ ] Managed build step

### Benchmark

Using zig allows creating small and fast functions.<br />
Running the basic [Echo demo](#echo) on _`arm64` (`256 MB`, Amazon Linux 2023)_:
- ❄️ `~11ms` cold-start duration
- ⚡ `~1.5ms` invocation duration
- 💾 `11 MB` max memory consumption
- ⚖️ `1.7 MB` function size (zip)

## Usage

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

## Demos

### Hello World
Returns a short message.

```zig
zig build demo:hello --release
```

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

### Response Streaming
Stream a response to the client.

👉 _Be sure to configure the function with streaming enabled._

```zig
zig build demo:stream --release
```

### Response Streaming: Fail
Stream a response to the client and eventually fail.

👉 _Be sure to configure the function with streaming enabled._

```zig
zig build demo:stream_throw --release
```


## License

The author and contributors are not responsible for any issues or damages caused
by the use of this software, part of it, or its derivatives. See [LICENSE](/LICENSE)
for the complete terms of use.

> [!NOTE]
> _AWS Lambda Runtime for Zig_ is not an official _Amazon Web Services_ software, nor
> is it affiliated with _Amazon Web Services, Inc_.

### Acknowledgments

- https://github.com/softprops/zig-lambda-runtime
- https://github.com/awslabs/aws-lambda-rust-runtime