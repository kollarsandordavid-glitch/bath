const std = @import("std");
const Store = @import("fs_store.zig").Store;
const Config = @import("config.zig").Config;
const json_util = @import("json_util.zig");

pub const Input = struct {
    step: u64,
    objective: []const u8,
    active_node_json: []const u8,
    tools: []const []const u8,
    artifact_paths: []const []const u8 = &.{},
};

pub const Snapshot = struct {
    content: []u8,
    sha256: []u8,
    history_path: []u8,
};

pub fn deinitSnapshot(allocator: std.mem.Allocator, snapshot: Snapshot) void {
    allocator.free(snapshot.content);
    allocator.free(snapshot.sha256);
    allocator.free(snapshot.history_path);
}

fn appendBounded(output: *std.ArrayList(u8), heading: []const u8, value: []const u8, budget: usize) !void {
    if (output.items.len >= budget) return;
    const prefix = try std.fmt.allocPrint(output.allocator, "\n## {s}\n\n", .{heading});
    defer output.allocator.free(prefix);
    if (prefix.len >= budget - output.items.len) return;
    try output.appendSlice(prefix);
    const remaining = budget - output.items.len;
    const take = @min(value.len, remaining);
    try output.appendSlice(value[0..take]);
}

fn readOrEmpty(allocator: std.mem.Allocator, store: *const Store, path: []const u8, limit: usize) ![]u8 {
    return store.readAlloc(path, limit) catch |err| switch (err) {
        error.FileNotFound => allocator.dupe(u8, ""),
        else => return err,
    };
}

pub fn build(allocator: std.mem.Allocator, store: *const Store, config: Config, input: Input) !Snapshot {
    const budget = config.context.max_main_context_bytes;
    if (budget < 2048) return error.ContextBudgetExceeded;
    const plan = try readOrEmpty(allocator, store, "state/plan.md", budget);
    defer allocator.free(plan);
    const progress = try readOrEmpty(allocator, store, "state/progress.md", budget);
    defer allocator.free(progress);
    const dag = try readOrEmpty(allocator, store, "tasks/dag.json", budget);
    defer allocator.free(dag);
    const manifest = try readOrEmpty(allocator, store, "state/manifest.json", budget);
    defer allocator.free(manifest);
    const recent = try readOrEmpty(allocator, store, "state/recent_actions.json", budget);
    defer allocator.free(recent);
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try output.appendSlice("# Execution Rules\n\nWorkspace files are authoritative. Full history belongs in events and artifacts. Use only this bounded reconstruction. Return one JSON object matching the action schema. Never expose hidden chain-of-thought. Validate before side effects.\n");
    const fixed_reserve: usize = 1024;
    const section_budget = if (budget > fixed_reserve) budget - fixed_reserve else return error.ContextBudgetExceeded;
    try appendBounded(&output, "Original Objective", input.objective, section_budget);
    try appendBounded(&output, "Active Task Node", input.active_node_json, section_budget);
    try appendBounded(&output, "Plan", plan, section_budget);
    try appendBounded(&output, "Progress", progress, section_budget);
    const index_limit = @min(dag.len, config.context.max_workspace_index_entries * 512);
    try appendBounded(&output, "Compact DAG", dag[0..index_limit], section_budget);
    const manifest_limit = @min(manifest.len, config.context.max_workspace_index_entries * 512);
    try appendBounded(&output, "Compact Manifest", manifest[0..manifest_limit], section_budget);
    for (input.artifact_paths) |path| {
        if (output.items.len >= section_budget) break;
        const snippet = store.readAlloc(path, config.context.max_artifact_snippet_bytes) catch continue;
        defer allocator.free(snippet);
        const heading = try std.fmt.allocPrint(allocator, "Artifact {s}", .{path});
        defer allocator.free(heading);
        try appendBounded(&output, heading, snippet, section_budget);
    }
    try appendBounded(&output, "Recent Actions", recent, section_budget);
    const tools_json = try json_util.stringifyCompactAlloc(allocator, input.tools);
    defer allocator.free(tools_json);
    try appendBounded(&output, "Available Actions and Tools", tools_json, section_budget);
    try appendBounded(&output, "Required Output Schema", "{\"rationale_summary\":\"concise public summary\",\"command\":\"create_tasks|delegate|call_tool|consolidate|mark_done|request_repair|finish|fail\",\"command_args\":{},\"expected_outputs\":[],\"acceptance_checks\":[]}", budget);
    if (output.items.len > budget) return error.ContextBudgetExceeded;
    const content = try output.toOwnedSlice();
    errdefer allocator.free(content);
    const hash = try store.hashHexAlloc(content);
    errdefer allocator.free(hash);
    const history_path = try std.fmt.allocPrint(allocator, "state/context/history/{d}-{s}.md", .{ input.step, hash });
    errdefer allocator.free(history_path);
    try store.atomicWrite(history_path, content);
    try store.atomicWrite("state/context/current.md", content);
    return .{ .content = content, .sha256 = hash, .history_path = history_path };
}
