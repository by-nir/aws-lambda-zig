//! Packs a Lambda executable into a zip archive.
//!
//! The build script runs it; there is no reason to call it by hand.
//!
//! ```console
//! zip_cli <executable> <archive>
//! ```
const std = @import("std");
const zip = @import("zip.zig");

/// The name AWS Lambda expects the executable to have.
const ENTRY_NAME = "bootstrap";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    const input_path = args.next() orelse return error.MissingInputPath;
    const output_path = args.next() orelse return error.MissingOutputPath;

    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, input_path, gpa, .unlimited);
    defer gpa.free(content);

    var archive: std.Io.Writer.Allocating = try .initCapacity(gpa, content.len);
    defer archive.deinit();

    try zip.writeArchive(gpa, &archive.writer, .{
        .name = ENTRY_NAME,
        .content = content,
    });

    try cwd.writeFile(io, .{
        .sub_path = output_path,
        .data = archive.written(),
    });
}
