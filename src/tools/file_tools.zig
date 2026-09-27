const std = @import("std");
const Store = @import("../fs_store.zig").Store;

pub fn read(store: *const Store, path: []const u8, max_bytes: usize) ![]u8 {
    return store.readAlloc(path, max_bytes);
}

pub fn write(store: *const Store, path: []const u8, data: []const u8) !void {
    if (!std.mem.startsWith(u8, path, "artifacts/") and !std.mem.startsWith(u8, path, "state/")) return error.ExecutionRejected;
    try store.atomicWrite(path, data);
}

pub fn list(allocator: std.mem.Allocator, store: *const Store, relative: []const u8, limit: usize) ![]u8 {
    try Store.validateRelative(relative);
    const absolute = try store.absolutePath(relative);
    defer allocator.free(absolute);
    var directory = try std.fs.openDirAbsolute(absolute, .{ .iterate = true });
    defer directory.close();
    var names = std.ArrayList([]u8).init(allocator);
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit();
    }
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (names.items.len >= limit) break;
        try names.append(try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    for (names.items) |name| try output.writer().print("{s}\n", .{name});
    return output.toOwnedSlice();
}

pub fn search(allocator: std.mem.Allocator, store: *const Store, relative: []const u8, needle: []const u8, max_file_bytes: usize, limit: usize) ![]u8 {
    try Store.validateRelative(relative);
    const absolute = try store.absolutePath(relative);
    defer allocator.free(absolute);
    var directory = try std.fs.openDirAbsolute(absolute, .{ .iterate = true });
    defer directory.close();
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var found: usize = 0;
    while (try walker.next()) |entry| {
        if (found >= limit or entry.kind != .file) continue;
        const relative_file = try std.fs.path.join(allocator, &.{ relative, entry.path });
        defer allocator.free(relative_file);
        const data = store.readAlloc(relative_file, max_file_bytes) catch continue;
        defer allocator.free(data);
        if (std.mem.indexOf(u8, data, needle)) |position| {
            try output.writer().print("{s}:{d}\n", .{ relative_file, position });
            found += 1;
        }
    }
    return output.toOwnedSlice();
}
