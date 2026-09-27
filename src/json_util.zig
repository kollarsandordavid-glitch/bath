const std = @import("std");

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.stringifyAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

pub fn stringifyCompactAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.stringifyAlloc(allocator, value, .{});
}

pub fn parse(comptime T: type, allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, data, .{ .ignore_unknown_fields = false });
}

pub fn redactAlloc(allocator: std.mem.Allocator, text: []const u8, secret: []const u8) ![]u8 {
    if (secret.len == 0) return allocator.dupe(u8, text);
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, secret)) |position| {
        try output.appendSlice(text[cursor..position]);
        try output.appendSlice("[REDACTED]");
        cursor = position + secret.len;
    }
    try output.appendSlice(text[cursor..]);
    return output.toOwnedSlice();
}

pub fn requireObjectField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.InvalidJson;
}
