//! Writes a zip archive that holds a single file.
//!
//! AWS Lambda unpacks the archive and runs the file inside it, so the file must
//! keep its executable bit. `std.zip` reads archives but cannot write them, so
//! the format is written here by hand, with its structs and constants.

const std = @import("std");
const zip = std.zip;
const testing = std.testing;
const Writer = std.Io.Writer;
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

/// Unix mode of a regular file that everyone may read and run: `rwxr-xr-x`.
pub const MODE_EXECUTABLE: u16 = 0o100755;

/// The archive holds a fixed timestamp, so the same input always produces the
/// same bytes. Stable output keeps the build cache useful.
/// This is the lowest time the DOS format can hold: 1980-01-01, 00:00.
const DOS_DATE: u16 = (1 << 5) | 1;
const DOS_TIME: u16 = 0;

/// The zip version a reader needs to unpack each compression method.
const VERSION_STORE: u16 = 10;
const VERSION_DEFLATE: u16 = 20;

/// The high byte tells the reader the archive was made on Unix. Without it a
/// reader ignores the file mode.
const VERSION_MADE_BY: u16 = (3 << 8) | VERSION_DEFLATE;

pub const Entry = struct {
    /// The file’s name inside the archive.
    name: []const u8,

    /// The file’s content.
    content: []const u8,

    /// The file’s Unix mode.
    mode: u16 = MODE_EXECUTABLE,
};

pub const Error = error{
    /// The zip format holds sizes in 32 bits. Larger files need zip64.
    EntryTooLarge,
    NameTooLong,
} || Allocator.Error || Writer.Error;

/// Writes a complete archive holding a single entry.
pub fn writeArchive(gpa: Allocator, out: *Writer, entry: Entry) Error!void {
    const name_len = std.math.cast(u16, entry.name.len) orelse return error.NameTooLong;
    const content_len = std.math.cast(u32, entry.content.len) orelse return error.EntryTooLarge;

    var deflated: Writer.Allocating = try .initCapacity(gpa, 1024);
    defer deflated.deinit();
    try deflate(gpa, &deflated.writer, entry.content);

    // Deflate makes small or already packed content bigger. Store it as-is then.
    const packed_smaller = deflated.written().len < entry.content.len;
    const method: zip.CompressionMethod = if (packed_smaller) .deflate else .store;
    const version = if (packed_smaller) VERSION_DEFLATE else VERSION_STORE;
    const data = if (packed_smaller) deflated.written() else entry.content;
    const data_len: u32 = @intCast(data.len);

    const crc = std.hash.crc.Crc32.hash(entry.content);
    const attributes = @as(u32, entry.mode) << 16;

    try out.writeStruct(zip.LocalFileHeader{
        .signature = zip.local_file_header_sig,
        .version_needed_to_extract = version,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = method,
        .last_modification_time = DOS_TIME,
        .last_modification_date = DOS_DATE,
        .crc32 = crc,
        .compressed_size = data_len,
        .uncompressed_size = content_len,
        .filename_len = name_len,
        .extra_len = 0,
    }, .little);
    try out.writeAll(entry.name);
    try out.writeAll(data);

    const directory_offset: u32 = @sizeOf(zip.LocalFileHeader) + name_len + data_len;

    try out.writeStruct(zip.CentralDirectoryFileHeader{
        .signature = zip.central_file_header_sig,
        .version_made_by = VERSION_MADE_BY,
        .version_needed_to_extract = version,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = method,
        .last_modification_time = DOS_TIME,
        .last_modification_date = DOS_DATE,
        .crc32 = crc,
        .compressed_size = data_len,
        .uncompressed_size = content_len,
        .filename_len = name_len,
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = attributes,
        .local_file_header_offset = 0,
    }, .little);
    try out.writeAll(entry.name);

    try out.writeStruct(zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = @sizeOf(zip.CentralDirectoryFileHeader) + name_len,
        .central_directory_offset = directory_offset,
        .comment_len = 0,
    }, .little);
}

/// Packs the content as a raw deflate stream, the form zip expects.
fn deflate(gpa: Allocator, out: *Writer, content: []const u8) Error!void {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    var compress = try flate.Compress.init(out, window, .raw, .default);
    try compress.writer.writeAll(content);
    try compress.finish();
}

/// Reads back the archive’s single central directory header.
///
/// It does not use `zip.EndRecord.findBuffer`, which fails to compile in Zig
/// 0.16: the function returns `error.EndOfStream`, which its own error set
/// leaves out. The archive carries no comment, so the end record is simply the
/// last bytes of it.
fn readEntryHeader(archive: []const u8) !zip.CentralDirectoryFileHeader {
    var end: std.Io.Reader = .fixed(archive[archive.len - @sizeOf(zip.EndRecord) ..]);
    const end_record = try end.takeStruct(zip.EndRecord, .little);
    try testing.expectEqualSlices(u8, &zip.end_record_sig, &end_record.signature);
    try testing.expectEqual(1, end_record.record_count_total);

    var directory: std.Io.Reader = .fixed(archive[end_record.central_directory_offset..]);
    return directory.takeStruct(zip.CentralDirectoryFileHeader, .little);
}

test "std.zip reads back the archive" {
    const gpa = testing.allocator;
    const io = testing.io;

    // Repeating content, so deflate has something to pack.
    var content: [4096]u8 = undefined;
    for (&content, 0..) |*byte, i| byte.* = @truncate(i / 16);

    var archive: Writer.Allocating = .init(gpa);
    defer archive.deinit();
    try writeArchive(gpa, &archive.writer, .{
        .name = "bootstrap",
        .content = &content,
    });

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lambda.zip", .data = archive.written() });

    var file = try tmp.dir.openFile(io, "lambda.zip", .{});
    defer file.close(io);
    var read_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);

    var entries: zip.Iterator = try .init(&file_reader);
    const entry = (try entries.next()).?;
    try testing.expectEqual(null, try entries.next());

    try testing.expectEqual(zip.CompressionMethod.deflate, entry.compression_method);
    try testing.expectEqual(content.len, entry.uncompressed_size);
    try testing.expect(entry.compressed_size < content.len);

    // Unpack the entry and compare it to what went in.
    var name_buffer: [32]u8 = undefined;
    try entry.extract(&file_reader, .{}, &name_buffer, tmp.dir);
    try testing.expectEqualStrings("bootstrap", name_buffer[0..entry.filename_len]);

    const unpacked = try tmp.dir.readFileAlloc(io, "bootstrap", gpa, .unlimited);
    defer gpa.free(unpacked);
    try testing.expectEqualSlices(u8, &content, unpacked);
}

test "the entry stays executable" {
    const gpa = testing.allocator;

    var archive: Writer.Allocating = .init(gpa);
    defer archive.deinit();
    try writeArchive(gpa, &archive.writer, .{
        .name = "bootstrap",
        .content = "#!/bin/sh\necho hello\n",
    });

    const header = try readEntryHeader(archive.written());
    try testing.expectEqual(@as(u32, MODE_EXECUTABLE) << 16, header.external_file_attributes);

    // The mode only counts when the archive says it was made on Unix.
    try testing.expectEqual(3, header.version_made_by >> 8);
}

test "content deflate cannot shrink is stored" {
    const gpa = testing.allocator;

    // Random bytes do not compress.
    var content: [512]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    prng.random().bytes(&content);

    var archive: Writer.Allocating = .init(gpa);
    defer archive.deinit();
    try writeArchive(gpa, &archive.writer, .{
        .name = "bootstrap",
        .content = &content,
    });

    const header = try readEntryHeader(archive.written());
    try testing.expectEqual(zip.CompressionMethod.store, header.compression_method);
    try testing.expectEqual(content.len, header.compressed_size);
    try testing.expectEqual(content.len, header.uncompressed_size);
}

test "the same content always gives the same bytes" {
    const gpa = testing.allocator;
    const entry: Entry = .{ .name = "bootstrap", .content = "the same every time" };

    var first: Writer.Allocating = .init(gpa);
    defer first.deinit();
    try writeArchive(gpa, &first.writer, entry);

    var second: Writer.Allocating = .init(gpa);
    defer second.deinit();
    try writeArchive(gpa, &second.writer, entry);

    try testing.expectEqualSlices(u8, first.written(), second.written());
}
