const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const test_alloc = testing.allocator;

const KeyVal = @This();

key: []const u8,
value: []const u8,

pub fn split(string: []const u8, delimeter: []const u8) ?KeyVal {
    const index = mem.indexOf(u8, string, delimeter) orelse return null;
    const skip = index + delimeter.len;
    return .{
        .key = string[0..index],
        .value = string[skip..][0 .. string.len - skip],
    };
}

test split {
    try testing.expectEqual(null, split("foo", "="));

    try testing.expectEqualDeep(KeyVal{
        .key = "foo",
        .value = "bar",
    }, split("foo=bar", "="));

    try testing.expectEqualDeep(KeyVal{
        .key = "foo",
        .value = "bar",
    }, split("foo::bar", "::"));
}

pub fn join(self: KeyVal, allocator: Allocator, delimeter: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.key, delimeter, self.value });
}

test join {
    const kv = KeyVal{
        .key = "foo",
        .value = "bar",
    };

    const concat = try kv.join(test_alloc, "=");
    defer test_alloc.free(concat);

    try testing.expectEqualStrings("foo=bar", concat);
}
