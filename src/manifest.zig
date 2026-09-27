const std = @import("std");
const Store = @import("fs_store.zig").Store;
const json_util = @import("json_util.zig");

pub const Entry = struct {
    path: []const u8,
    artifact_type: []const u8,
    size: u64,
    sha256: []const u8,
    created_at: i64,
    modified_at: i64,
    producing_event: ?[]const u8 = null,
    semantic_tags: []const []const u8 = &.{},
};

pub const Manifest = struct { entries: []const Entry = &.{} };

pub fn update(allocator: std.mem.Allocator, store: *const Store, path: []const u8, artifact_type: []const u8, producing_event: ?[]const u8, tags: []const []const u8, max_bytes: usize) !void {
    const artifact = try store.readAlloc(path, max_bytes);
    defer allocator.free(artifact);
    const digest = try store.hashHexAlloc(artifact);
    defer allocator.free(digest);
    const now = std.time.milliTimestamp();
    const data = try store.readAlloc("state/manifest.json", max_bytes);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, data, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    var found = false;
    var entries = std.ArrayList(Entry).init(allocator);
    defer entries.deinit();
    for (parsed.value.entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            try entries.append(.{ .path = path, .artifact_type = artifact_type, .size = artifact.len, .sha256 = digest, .created_at = entry.created_at, .modified_at = now, .producing_event = producing_event, .semantic_tags = tags });
            found = true;
        } else try entries.append(entry);
    }
    if (!found) try entries.append(.{ .path = path, .artifact_type = artifact_type, .size = artifact.len, .sha256 = digest, .created_at = now, .modified_at = now, .producing_event = producing_event, .semantic_tags = tags });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    const output = try json_util.stringifyAlloc(allocator, Manifest{ .entries = entries.items });
    defer allocator.free(output);
    try store.atomicWrite("state/manifest.json", output);
}

pub fn verify(allocator: std.mem.Allocator, store: *const Store, max_bytes: usize) !void {
    const data = try store.readAlloc("state/manifest.json", max_bytes);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, data, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    for (parsed.value.entries) |entry| {
        const actual = try store.hashFileHexAlloc(entry.path, max_bytes);
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, entry.sha256)) return error.IntegrityFailure;
    }
}
