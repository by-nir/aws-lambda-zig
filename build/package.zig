//! Build helpers that pack a Lambda executable into a zip archive.
const std = @import("std");

/// Builds the packaging tool for the machine running the build.
pub fn addZipTool(b: *std.Build, source: std.Build.LazyPath) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "zip",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            // Packing a large executable in a debug build is slow.
            .optimize = .ReleaseSafe,
        }),
    });
}

/// Packs the executable into a zip archive named `bootstrap`.
/// Returns the archive’s path inside the build cache, keyed by the
/// executable’s content.
pub fn addZipArchive(
    b: *std.Build,
    tool: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addFileArg(exe.getEmittedBin());
    return run.addOutputFileArg("bootstrap.zip");
}
