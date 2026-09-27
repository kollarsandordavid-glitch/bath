const std = @import("std");
const Store = @import("fs_store.zig").Store;
const json_util = @import("json_util.zig");

pub const Status = enum { started, succeeded, failed, cancelled };

pub const ArtifactHash = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Event = struct {
    event_id: []const u8,
    step: u64,
    timestamp: i64,
    actor_type: []const u8,
    agent_id: []const u8,
    task_node_id: []const u8,
    parent_task_node_id: ?[]const u8 = null,
    action_kind: []const u8,
    input_references: []const []const u8 = &.{},
    output_references: []const []const u8 = &.{},
    tool_call_id: ?[]const u8 = null,
    llm_call_id: ?[]const u8 = null,
    context_snapshot_hash: ?[]const u8 = null,
    status: Status,
    error_details: ?[]const u8 = null,
    artifact_hashes: []const ArtifactHash = &.{},
};

pub fn append(allocator: std.mem.Allocator, store: *const Store, event: Event) !void {
    const line = try json_util.stringifyCompactAlloc(allocator, event);
    defer allocator.free(line);
    try store.appendLine("state/events.jsonl", line);
}

pub fn replay(allocator: std.mem.Allocator, store: *const Store, max_bytes: usize) !std.ArrayList(Event) {
    const data = try store.readAlloc("state/events.jsonl", max_bytes);
    defer allocator.free(data);
    var result = std.ArrayList(Event).init(allocator);
    errdefer {
        for (result.items) |event| freeEvent(allocator, event);
        result.deinit();
    }
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = try std.json.parseFromSlice(Event, allocator, line, .{ .ignore_unknown_fields = false });
        try result.append(try cloneEvent(allocator, parsed.value));
        parsed.deinit();
    }
    return result;
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |item| try allocator.dupe(u8, item) else null;
}

fn dupeStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var output = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(output);
    for (values, 0..) |value, index| output[index] = try allocator.dupe(u8, value);
    return output;
}

fn cloneEvent(allocator: std.mem.Allocator, value: Event) !Event {
    var hashes = try allocator.alloc(ArtifactHash, value.artifact_hashes.len);
    for (value.artifact_hashes, 0..) |hash, index| hashes[index] = .{ .path = try allocator.dupe(u8, hash.path), .sha256 = try allocator.dupe(u8, hash.sha256) };
    return .{
        .event_id = try allocator.dupe(u8, value.event_id),
        .step = value.step,
        .timestamp = value.timestamp,
        .actor_type = try allocator.dupe(u8, value.actor_type),
        .agent_id = try allocator.dupe(u8, value.agent_id),
        .task_node_id = try allocator.dupe(u8, value.task_node_id),
        .parent_task_node_id = try dupeOptional(allocator, value.parent_task_node_id),
        .action_kind = try allocator.dupe(u8, value.action_kind),
        .input_references = try dupeStrings(allocator, value.input_references),
        .output_references = try dupeStrings(allocator, value.output_references),
        .tool_call_id = try dupeOptional(allocator, value.tool_call_id),
        .llm_call_id = try dupeOptional(allocator, value.llm_call_id),
        .context_snapshot_hash = try dupeOptional(allocator, value.context_snapshot_hash),
        .status = value.status,
        .error_details = try dupeOptional(allocator, value.error_details),
        .artifact_hashes = hashes,
    };
}

pub fn freeEvent(allocator: std.mem.Allocator, event: Event) void {
    allocator.free(event.event_id);
    allocator.free(event.actor_type);
    allocator.free(event.agent_id);
    allocator.free(event.task_node_id);
    if (event.parent_task_node_id) |value| allocator.free(value);
    allocator.free(event.action_kind);
    for (event.input_references) |value| allocator.free(value);
    allocator.free(event.input_references);
    for (event.output_references) |value| allocator.free(value);
    allocator.free(event.output_references);
    if (event.tool_call_id) |value| allocator.free(value);
    if (event.llm_call_id) |value| allocator.free(value);
    if (event.context_snapshot_hash) |value| allocator.free(value);
    if (event.error_details) |value| allocator.free(value);
    for (event.artifact_hashes) |hash| {
        allocator.free(hash.path);
        allocator.free(hash.sha256);
    }
    allocator.free(event.artifact_hashes);
}
