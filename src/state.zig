const std = @import("std");
const Store = @import("fs_store.zig").Store;
const config_module = @import("config.zig");
const json_util = @import("json_util.zig");
const ids = @import("ids.zig");

pub const Task = struct {
    id: []const u8,
    objective: []const u8,
    created_at: i64,
    status: []const u8,
};

pub const RecentAction = struct {
    step: u64,
    timestamp: i64,
    actor: []const u8,
    action: []const u8,
    status: []const u8,
    artifact: ?[]const u8 = null,
};

pub fn initialize(allocator: std.mem.Allocator, workspace: []const u8, objective: []const u8, config: config_module.Config) !void {
    var store = try Store.init(allocator, workspace);
    defer store.deinit();
    const directories = [_][]const u8{
        "state/context/history", "state/snapshots", "tasks", "artifacts/documents", "artifacts/extracted_text", "artifacts/answers", "artifacts/reports", "artifacts/code", "artifacts/data", "logs/agent", "logs/tool", "logs/llm", "cache", "locks",
    };
    for (directories) |directory| try store.makePath(directory);
    const task_id = try ids.generate(allocator, "task");
    defer allocator.free(task_id);
    const task = Task{ .id = task_id, .objective = objective, .created_at = std.time.milliTimestamp(), .status = "ready" };
    const task_json = try json_util.stringifyAlloc(allocator, task);
    defer allocator.free(task_json);
    try store.atomicWrite("task.json", task_json);
    var resolved = config;
    resolved.workspace_root = store.root;
    const config_json = try json_util.stringifyAlloc(allocator, resolved);
    defer allocator.free(config_json);
    try store.atomicWrite("config.resolved.json", config_json);
    try store.atomicWrite("state/manifest.json", "{\n  \"entries\": []\n}\n");
    try store.atomicWrite("state/events.jsonl", "");
    try store.atomicWrite("state/recent_actions.json", "[]\n");
    try store.atomicWrite("state/plan.md", "# Plan\n\nThe root task is ready for coordinator decomposition.\n");
    try store.atomicWrite("state/progress.md", "# Progress\n\nNo scheduler steps have completed.\n");
    try store.atomicWrite("state/context/current.md", "");
    const dag_json = try std.fmt.allocPrint(allocator, "{{\n  \"nodes\": [{{\n    \"id\": \"{s}\",\n    \"parent_id\": null,\n    \"dependencies\": [],\n    \"status\": \"ready\",\n    \"assigned_agent\": \"coordinator\",\n    \"objective\": {f},\n    \"acceptance_criteria\": [\"A final report artifact exists and addresses the objective\"],\n    \"input_artifacts\": [],\n    \"output_artifacts\": [],\n    \"retry_count\": 0,\n    \"error_history\": [],\n    \"creation_event\": null,\n    \"completion_event\": null\n  }}],\n  \"root_id\": \"{s}\"\n}}\n", .{ task_id, std.json.fmt(objective, .{}), task_id });
    defer allocator.free(dag_json);
    try store.atomicWrite("tasks/dag.json", dag_json);
}

pub fn acquireLock(store: *const Store) !void {
    var root_dir = try std.fs.openDirAbsolute(store.root, .{});
    defer root_dir.close();
    _ = root_dir.createFile("locks/workspace.lock", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.WorkspaceLocked,
        else => return err,
    };
}

pub fn releaseLock(store: *const Store) void {
    var root_dir = std.fs.openDirAbsolute(store.root, .{}) catch return;
    defer root_dir.close();
    root_dir.deleteFile("locks/workspace.lock") catch {};
}

pub fn pushRecentAction(allocator: std.mem.Allocator, store: *const Store, action: RecentAction, limit: usize) !void {
    const data = try store.readAlloc("state/recent_actions.json", 4 * 1024 * 1024);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice([]RecentAction, allocator, data, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const old = parsed.value;
    const keep = @min(old.len, limit - 1);
    const start = old.len - keep;
    var next = try allocator.alloc(RecentAction, keep + 1);
    defer allocator.free(next);
    @memcpy(next[0..keep], old[start..]);
    next[keep] = action;
    const output = try json_util.stringifyAlloc(allocator, next);
    defer allocator.free(output);
    try store.atomicWrite("state/recent_actions.json", output);
}
