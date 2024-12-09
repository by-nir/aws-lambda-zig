const std = @import("std");
const Scanner = std.json.Scanner;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;
const KeyVal = @import("../utils/KeyVal.zig");

pub const Error = error{InvalidInput} || std.json.Error;

pub fn inputError() Error {
    @branchHint(.cold);
    return Error.InvalidInput;
}

pub fn nextExpect(scanner: *Scanner, comptime expected: std.json.Token) !void {
    try nextExpectErr(scanner, expected, Error.InvalidInput);
}

pub fn nextExpectErr(scanner: *Scanner, comptime expected: std.json.Token, err: anyerror) !void {
    switch (try scanner.next()) {
        expected => {},
        else => {
            @branchHint(.cold);
            return err;
        },
    }
}

test nextExpectErr {
    var scanner = Scanner.initCompleteInput(test_alloc, "null");
    defer scanner.deinit();
    try nextExpectErr(&scanner, .null, error.Fail);

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "108");
    try testing.expectError(error.Fail, nextExpectErr(&scanner, .null, error.Fail));
}

pub fn nextString(scanner: *Scanner) ![]const u8 {
    return switch (try scanner.next()) {
        .string => |s| s,
        else => inputError(),
    };
}

test nextString {
    var scanner = Scanner.initCompleteInput(test_alloc, "\"foo\"");
    defer scanner.deinit();
    try testing.expectEqualStrings("foo", try nextString(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, nextString(&scanner));
}

pub fn nextStringOptional(scanner: *Scanner) !?[]const u8 {
    return switch (try scanner.next()) {
        .null => null,
        .string => |s| if (s.len > 0) s else null,
        else => inputError(),
    };
}

test nextStringOptional {
    var scanner = Scanner.initCompleteInput(test_alloc, "\"foo\"");
    defer scanner.deinit();
    try testing.expectEqualDeep("foo", try nextStringOptional(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"\"");
    try testing.expectEqual(null, try nextStringOptional(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectEqual(null, try nextStringOptional(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "108");
    try testing.expectError(Error.InvalidInput, nextStringOptional(&scanner));
}

pub fn nextStringEqual(scanner: *Scanner, expected: []const u8) !void {
    try nextStringEqualErr(scanner, expected, Error.InvalidInput);
}

pub fn nextStringEqualErr(scanner: *Scanner, expected: []const u8, err: anyerror) !void {
    if (!std.mem.eql(u8, expected, try nextString(scanner))) {
        @branchHint(.cold);
        return err;
    }
}

test nextStringEqualErr {
    var scanner = Scanner.initCompleteInput(test_alloc, "\"foo\"");
    defer scanner.deinit();
    try nextStringEqualErr(&scanner, "foo", error.Fail);

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"bar\"");
    try testing.expectEqual(error.Fail, nextStringEqualErr(&scanner, "foo", error.Fail));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, nextStringEqualErr(&scanner, "foo", error.Fail));
}

pub fn nextNumber(scanner: *Scanner, comptime T: type) !T {
    return switch (try scanner.next()) {
        .number => |s| switch (@typeInfo(T)) {
            .int => std.fmt.parseInt(T, s, 10),
            .float => std.fmt.parseFloat(T, s),
            else => unreachable,
        },
        else => inputError(),
    };
}

test nextNumber {
    var scanner = Scanner.initCompleteInput(test_alloc, "-1024");
    defer scanner.deinit();
    try testing.expectEqual(-1024, try nextNumber(&scanner, i16));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "1.08");
    try testing.expectEqual(1.08, try nextNumber(&scanner, f32));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "108");
    try testing.expectEqual(108.0, try nextNumber(&scanner, f32));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, nextNumber(&scanner, u8));
}

pub fn nextBool(scanner: *Scanner) !bool {
    switch (try scanner.next()) {
        .true => return true,
        .false => return false,
        else => return inputError(),
    }
}

test nextBool {
    var scanner = Scanner.initCompleteInput(test_alloc, "true");
    defer scanner.deinit();
    try testing.expectEqual(true, try nextBool(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "false");
    try testing.expectEqual(false, try nextBool(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, nextBool(&scanner));
}

pub const ArrayIterator = struct {
    scanner: *Scanner,
    done: bool = false,

    pub fn begin(scanner: *Scanner) !@This() {
        try nextExpect(scanner, .array_begin);
        return .{ .scanner = scanner };
    }

    pub fn next(self: *@This()) !bool {
        if (self.done) {
            @branchHint(.cold);
            return false;
        } else switch (try self.scanner.peekNextTokenType()) {
            .array_end => {
                _ = try self.scanner.next();
                self.done = true;
                return false;
            },
            else => {
                @branchHint(.likely);
                return true;
            },
        }
    }
};

test ArrayIterator {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\[ "foo", "bar" ]
    );
    defer scanner.deinit();

    var it = try ArrayIterator.begin(&scanner);
    try testing.expectEqual(true, try it.next());
    try scanner.skipValue();
    try testing.expectEqual(true, try it.next());
    try scanner.skipValue();
    try testing.expectEqual(false, try it.next());
    try testing.expectEqual(false, try it.next());

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, ArrayIterator.begin(&scanner));
}

pub const ObjectIterator = struct {
    scanner: *Scanner,
    done: bool = false,

    pub fn begin(scanner: *Scanner) !@This() {
        try nextExpect(scanner, .object_begin);
        return .{ .scanner = scanner };
    }

    pub fn next(self: *@This()) !?[]const u8 {
        if (self.done) {
            @branchHint(.cold);
            return null;
        } else switch (try self.scanner.next()) {
            .object_end => {
                self.done = true;
                return null;
            },
            .string => |key| {
                @branchHint(.likely);
                return key;
            },
            else => unreachable,
        }
    }
};

test ObjectIterator {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "foo": null,
        \\  "bar": null
        \\}
    );
    defer scanner.deinit();

    var it = try ObjectIterator.begin(&scanner);
    try testing.expectEqualDeep("foo", try it.next());
    try scanner.skipValue();
    try testing.expectEqualDeep("bar", try it.next());
    try scanner.skipValue();
    try testing.expectEqual(null, try it.next());
    try testing.expectEqual(null, try it.next());

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, ObjectIterator.begin(&scanner));
}

pub const Union = struct {
    scanner: *Scanner,
    key: []const u8,

    pub fn begin(scanner: *Scanner) !@This() {
        try nextExpect(scanner, .object_begin);
        return .{
            .scanner = scanner,
            .key = try nextString(scanner),
        };
    }

    pub fn end(self: Union) !void {
        try nextExpect(self.scanner, .object_end);
    }

    pub fn endErr(self: Union, err: anyerror) !void {
        try nextExpectErr(self.scanner, .object_end, err);
    }
};

test Union {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\{ "foo": null }
    );
    defer scanner.deinit();

    var u = try Union.begin(&scanner);
    try testing.expectEqualStrings("foo", u.key);
    try scanner.skipValue();
    try u.end();

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "foo": null,
        \\  "bar": null
        \\}
    );
    u = try Union.begin(&scanner);
    try scanner.skipValue();
    try testing.expectError(Error.InvalidInput, u.end());

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "{}");
    try testing.expectError(Error.InvalidInput, Union.begin(&scanner));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, Union.begin(&scanner));
}

pub fn nextKeyValList(allocator: Allocator, scanner: *Scanner, delimeter: []const u8) ![]const KeyVal {
    var list = std.ArrayList(KeyVal).init(allocator);
    errdefer list.deinit();

    var it = try ArrayIterator.begin(scanner);
    while (try it.next()) {
        const concat = try nextString(scanner);
        const kv = KeyVal.split(concat, delimeter) orelse return inputError();
        try list.append(kv);
    }

    return list.toOwnedSlice();
}

test nextKeyValList {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\[
        \\  "foo:bar",
        \\  "baz:qux"
        \\]
    );
    defer scanner.deinit();

    const list = try nextKeyValList(test_alloc, &scanner, ":");
    defer test_alloc.free(list);
    try testing.expectEqualDeep(&[_]KeyVal{ .{
        .key = "foo",
        .value = "bar",
    }, .{
        .key = "baz",
        .value = "qux",
    } }, list);

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc,
        \\[ "foo=bar" ]
    );
    try testing.expectError(Error.InvalidInput, nextKeyValList(test_alloc, &scanner, ":"));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, nextKeyValList(test_alloc, &scanner, ":"));
}

pub fn nextKeyValMap(allocator: Allocator, scanner: *Scanner) ![]const KeyVal {
    var list = std.ArrayList(KeyVal).init(allocator);
    errdefer list.deinit();

    var it = try ObjectIterator.begin(scanner);
    while (try it.next()) |key| {
        try list.append(.{
            .key = key,
            .value = try nextString(scanner),
        });
    }

    return list.toOwnedSlice();
}

test nextKeyValMap {
    var scanner = Scanner.initCompleteInput(test_alloc,
        \\{
        \\  "foo": "bar",
        \\  "baz": "qux"
        \\}
    );
    defer scanner.deinit();

    const list = try nextKeyValMap(test_alloc, &scanner);
    defer test_alloc.free(list);
    try testing.expectEqualDeep(&[_]KeyVal{ .{
        .key = "foo",
        .value = "bar",
    }, .{
        .key = "baz",
        .value = "qux",
    } }, list);

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, nextKeyValMap(test_alloc, &scanner));
}
