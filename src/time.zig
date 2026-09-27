const std = @import("std");

pub fn unixMillis() i64 {
    return std.time.milliTimestamp();
}

pub fn timestampAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{unixMillis()});
}
