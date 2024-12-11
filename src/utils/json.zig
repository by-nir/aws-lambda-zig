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

/// If passed an allocator, the string will be allocated.
/// Otherwise, returns `error.InvalidInput` if the value is escaped.
pub fn nextString(scanner: *Scanner, allocator: ?Allocator) ![]const u8 {
    const next = if (allocator) |alloc|
        try scanner.nextAlloc(alloc, .alloc_always)
    else
        try scanner.next();

    return switch (next) {
        .string, .allocated_string => |s| s,
        else => inputError(),
    };
}

test nextString {
    var scanner = Scanner.initCompleteInput(test_alloc, "\"foo\"");
    defer scanner.deinit();
    try testing.expectEqualStrings("foo", try nextString(&scanner, null));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"f\\\"o\\\"o\"");
    try testing.expectError(Error.InvalidInput, nextString(&scanner, null));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"f\\\"o\\\"o\"");
    const escaped = try nextString(&scanner, test_alloc);
    defer test_alloc.free(escaped);
    try testing.expectEqualStrings("f\"o\"o", escaped);

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, nextString(&scanner, null));
}

/// If passed an allocator, the string will be allocated.
/// Otherwise, returns `error.InvalidInput` if the value is escaped.
pub fn nextStringOptional(scanner: *Scanner, allocator: ?Allocator) !?[]const u8 {
    const next = if (allocator) |alloc|
        try scanner.nextAlloc(alloc, .alloc_always)
    else
        try scanner.next();

    return switch (next) {
        .null => null,
        .string, .allocated_string => |s| if (s.len > 0) s else null,
        else => inputError(),
    };
}

test nextStringOptional {
    var scanner = Scanner.initCompleteInput(test_alloc, "\"\"");
    defer scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"\"");
    try testing.expectEqual(null, try nextStringOptional(&scanner, null));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectEqual(null, try nextStringOptional(&scanner, null));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"foo\"");
    try testing.expectEqualDeep("foo", try nextStringOptional(&scanner, null));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"f\\\"o\\\"o\"");
    try testing.expectError(Error.InvalidInput, nextStringOptional(&scanner, null));

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "\"f\\\"o\\\"o\"");
    const escaped = try nextStringOptional(&scanner, test_alloc);
    defer test_alloc.free(escaped.?);
    try testing.expectEqualDeep("f\"o\"o", escaped);

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "108");
    try testing.expectError(Error.InvalidInput, nextStringOptional(&scanner, null));
}

/// Assumes expected string does not require escaping.
pub fn nextStringEqual(scanner: *Scanner, expected: []const u8) !void {
    try nextStringEqualErr(scanner, expected, Error.InvalidInput);
}

/// Assumes expected string does not require escaping.
pub fn nextStringEqualErr(scanner: *Scanner, expected: []const u8, err: anyerror) !void {
    if (!std.mem.eql(u8, expected, try nextString(scanner, null))) {
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
    allocator: Allocator,
    scanner: *Scanner,
    done: bool = false,
    prev_alloc: ?[]const u8 = null,

    pub fn init(allocator: Allocator, scanner: *Scanner) !@This() {
        try nextExpect(scanner, .object_begin);
        return .{
            .allocator = allocator,
            .scanner = scanner,
        };
    }

    /// Only required to call if deinit before exhausted.
    /// Safe to call after exhausted.
    pub fn deinit(self: *@This()) void {
        self.freePrev();
    }

    pub fn next(self: *@This()) !?[]const u8 {
        return self.nextInternal(false);
    }

    pub fn nextAlloc(self: *@This()) !?[]const u8 {
        return self.nextInternal(true);
    }

    fn nextInternal(self: *@This(), comptime alloc: bool) !?[]const u8 {
        // If the previous key was allocated, free it.
        self.freePrev();

        if (self.done) {
            @branchHint(.cold);
            return null;
        } else {
            const when: std.json.AllocWhen = if (alloc) .alloc_always else .alloc_if_needed;
            switch (try self.scanner.nextAlloc(self.allocator, when)) {
                .object_end => {
                    self.done = true;
                    return null;
                },
                .string => |key| if (!alloc) return key else unreachable,
                .allocated_string => |key| {
                    if (!alloc) self.prev_alloc = key;
                    return key;
                },
                else => unreachable,
            }
        }
    }

    fn freePrev(self: *@This()) void {
        const str = self.prev_alloc orelse return;
        self.allocator.free(str);
        self.prev_alloc = null;
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

    var it = try ObjectIterator.init(test_alloc, &scanner);
    errdefer it.deinit();
    try testing.expectEqualDeep("foo", try it.next());
    try scanner.skipValue();
    try testing.expectEqualDeep("bar", try it.next());
    try scanner.skipValue();
    try testing.expectEqual(null, try it.next());
    try testing.expectEqual(null, try it.next());

    scanner.deinit();
    scanner = Scanner.initCompleteInput(test_alloc, "null");
    try testing.expectError(Error.InvalidInput, ObjectIterator.init(test_alloc, &scanner));
}

pub const Union = struct {
    scanner: *Scanner,
    key: []const u8,

    pub fn begin(scanner: *Scanner) !@This() {
        try nextExpect(scanner, .object_begin);
        return .{
            .scanner = scanner,
            .key = try nextString(scanner, null),
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

/// Call `freeKeyValList` to free the list and its KV pairs.
pub fn nextKeyValList(allocator: Allocator, scanner: *Scanner, delimeter: []const u8) ![]const KeyVal {
    var list = std.ArrayList(KeyVal).init(allocator);
    errdefer {
        for (list.items) |kv| kv.deinitSplitted(allocator);
        list.deinit();
    }

    var it = try ArrayIterator.begin(scanner);
    while (try it.next()) {
        const concat = try nextString(scanner, allocator);
        errdefer allocator.free(concat);
        const kv = KeyVal.split(concat, delimeter) orelse return inputError();
        try list.append(kv);
    }

    return list.toOwnedSlice();
}

pub fn freeKeyValList(allocator: Allocator, list: []const KeyVal) void {
    for (list) |kv| kv.deinitSplitted(allocator);
    allocator.free(list);
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
    defer freeKeyValList(test_alloc, list);
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

/// Call `freeKeyValMap` to free the list and its KV pairs.
pub fn nextKeyValMap(allocator: Allocator, scanner: *Scanner) ![]const KeyVal {
    var list = std.ArrayList(KeyVal).init(allocator);
    errdefer {
        for (list.items) |kv| kv.deinit(allocator);
        list.deinit();
    }

    var it = try ObjectIterator.init(allocator, scanner);
    errdefer it.deinit();
    while (try it.nextAlloc()) |key| {
        const kv = KeyVal{
            .key = key,
            .value = try nextString(scanner, allocator),
        };
        errdefer kv.deinit(allocator);
        try list.append(kv);
    }

    return list.toOwnedSlice();
}

pub fn freeKeyValMap(allocator: Allocator, list: []const KeyVal) void {
    for (list) |kv| kv.deinit(allocator);
    allocator.free(list);
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
    defer freeKeyValMap(test_alloc, list);
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
