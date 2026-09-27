const std = @import("std");
const Store = @import("fs_store.zig").Store;
const events = @import("events.zig");
const manifest = @import("manifest.zig");

pub fn run(allocator: std.mem.Allocator, store: *const Store, step: u64, max_bytes: usize) ![]u8 {
    var replayed = try events.replay(allocator, store, max_bytes);
    defer {
        for (replayed.items) |event| events.freeEvent(allocator, event);
        replayed.deinit();
    }
    var progress = std.ArrayList(u8).init(allocator);
    defer progress.deinit();
    try progress.writer().print("# Progress\n\nConsolidated through step {d}.\n\n", .{step});
    const start = if (replayed.items.len > 100) replayed.items.len - 100 else 0;
    for (replayed.items[start..]) |event| try progress.writer().print("- Step {d}: {s} by {s} was {s}.\n", .{ event.step, event.action_kind, event.agent_id, @tagName(event.status) });
    try store.atomicWrite("state/progress.md", progress.items);
    const path = try std.fmt.allocPrint(allocator, "state/snapshots/consolidation-{d}.md", .{step});
    errdefer allocator.free(path);
    var artifact = std.ArrayList(u8).init(allocator);
    defer artifact.deinit();
    try artifact.writer().print("# Consolidation {d}\n\nThis artifact references the authoritative event log and summarizes events through step {d}.\n\n", .{ step, step });
    for (replayed.items[start..]) |event| try artifact.writer().print("- `{s}` step {d} `{s}` `{s}` outputs {any}\n", .{ event.event_id, event.step, event.action_kind, @tagName(event.status), event.output_references });
    try store.atomicWrite(path, artifact.items);
    try manifest.update(allocator, store, path, "consolidation", null, &.{"consolidation"}, max_bytes);
    return path;
}
