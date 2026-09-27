const std = @import("std");
const Store = @import("fs_store.zig").Store;
const json_util = @import("json_util.zig");

pub const Status = enum { pending, ready, running, blocked, done, failed, cancelled };
pub const AgentType = enum { coordinator, research, data_collection, coding, writing, document_review };

pub const Node = struct {
    id: []const u8,
    parent_id: ?[]const u8 = null,
    dependencies: []const []const u8 = &.{},
    status: Status = .pending,
    assigned_agent: AgentType,
    objective: []const u8,
    acceptance_criteria: []const []const u8 = &.{},
    input_artifacts: []const []const u8 = &.{},
    output_artifacts: []const []const u8 = &.{},
    retry_count: u8 = 0,
    error_history: []const []const u8 = &.{},
    creation_event: ?[]const u8 = null,
    completion_event: ?[]const u8 = null,
};

pub const Dag = struct {
    nodes: []const Node,
    root_id: []const u8,
};

pub fn load(allocator: std.mem.Allocator, store: *const Store) !std.json.Parsed(Dag) {
    const data = try store.readAlloc("tasks/dag.json", 16 * 1024 * 1024);
    defer allocator.free(data);
    return std.json.parseFromSlice(Dag, allocator, data, .{ .ignore_unknown_fields = false });
}

pub fn save(allocator: std.mem.Allocator, store: *const Store, dag: Dag) !void {
    try validate(dag);
    const output = try json_util.stringifyAlloc(allocator, dag);
    defer allocator.free(output);
    try store.atomicWrite("tasks/dag.json", output);
}

pub fn validate(dag: Dag) !void {
    if (find(dag, dag.root_id) == null) return error.InvalidTransition;
    for (dag.nodes, 0..) |node, index| {
        for (dag.nodes[index + 1 ..]) |other| if (std.mem.eql(u8, node.id, other.id)) return error.InvalidTransition;
        if (node.parent_id) |parent| {
            if (find(dag, parent) == null or std.mem.eql(u8, parent, node.id)) return error.InvalidTransition;
        }
        for (node.dependencies) |dependency| {
            if (find(dag, dependency) == null or std.mem.eql(u8, dependency, node.id)) return error.InvalidTransition;
            const dependency_node = find(dag, dependency).?;
            if (!sameParent(node, dependency_node)) return error.InvalidTransition;
        }
    }
    for (dag.nodes) |node| {
        var slow: ?[]const u8 = node.id;
        var fast: ?[]const u8 = node.id;
        while (fast != null) {
            slow = parentOf(dag, slow.?);
            fast = parentOf(dag, fast.?);
            if (fast) |value| fast = parentOf(dag, value);
            if (slow != null and fast != null and std.mem.eql(u8, slow.?, fast.?)) return error.InvalidTransition;
        }
    }
}

fn sameParent(a: Node, b: Node) bool {
    if (a.parent_id == null or b.parent_id == null) return a.parent_id == null and b.parent_id == null;
    return std.mem.eql(u8, a.parent_id.?, b.parent_id.?);
}

fn parentOf(dag: Dag, id: []const u8) ?[]const u8 {
    const node = find(dag, id) orelse return null;
    return node.parent_id;
}

pub fn find(dag: Dag, id: []const u8) ?Node {
    for (dag.nodes) |node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

pub fn nextRunnable(dag: Dag) ?usize {
    for (dag.nodes, 0..) |node, index| {
        if (node.status != .ready and node.status != .pending) continue;
        var dependencies_done = true;
        for (node.dependencies) |dependency| {
            const dependency_node = find(dag, dependency) orelse return null;
            if (dependency_node.status != .done) dependencies_done = false;
        }
        if (!dependencies_done) continue;
        if (hasIncompleteChildren(dag, node.id)) continue;
        return index;
    }
    return null;
}

pub fn hasIncompleteChildren(dag: Dag, parent_id: []const u8) bool {
    for (dag.nodes) |node| if (node.parent_id) |parent| {
        if (std.mem.eql(u8, parent, parent_id) and node.status != .done and node.status != .cancelled) return true;
    };
    return false;
}

pub fn canControl(dag: Dag, actor_id: []const u8, target_id: []const u8) bool {
    if (std.mem.eql(u8, actor_id, target_id)) return true;
    const target = find(dag, target_id) orelse return false;
    if (target.parent_id) |parent| return std.mem.eql(u8, parent, actor_id);
    return false;
}

pub fn transition(current: Status, next: Status) !void {
    const allowed = switch (current) {
        .pending => next == .ready or next == .blocked or next == .cancelled,
        .ready => next == .running or next == .blocked or next == .cancelled,
        .running => next == .done or next == .failed or next == .blocked or next == .ready,
        .blocked => next == .ready or next == .failed or next == .cancelled,
        .failed => next == .ready or next == .cancelled,
        .done, .cancelled => false,
    };
    if (!allowed) return error.InvalidTransition;
}
