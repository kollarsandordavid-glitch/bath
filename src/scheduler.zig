const std = @import("std");
const config_module = @import("config.zig");
const Store = @import("fs_store.zig").Store;
const state = @import("state.zig");
const dag_module = @import("task_dag.zig");
const context_builder = @import("context_builder.zig");
const registry = @import("tools/registry.zig");
const openai = @import("llm/openai_compatible.zig");
const coordinator = @import("agents/coordinator.zig");
const domain = @import("agents/domain.zig");
const atomic = @import("agents/atomic.zig");
const events = @import("events.zig");
const manifest = @import("manifest.zig");
const consolidation = @import("consolidation.zig");
const ids = @import("ids.zig");
const json_util = @import("json_util.zig");

pub const Outcome = enum { progressed, completed, failed, idle };

pub fn run(allocator: std.mem.Allocator, workspace: []const u8, single_step: bool) !Outcome {
    var store = try Store.init(allocator, workspace);
    defer store.deinit();
    if (!store.exists("task.json")) return error.WorkspaceNotInitialized;
    try state.acquireLock(&store);
    defer state.releaseLock(&store);
    const config_path = try store.absolutePath("config.resolved.json");
    defer allocator.free(config_path);
    var parsed_config = try config_module.load(allocator, config_path);
    defer parsed_config.deinit();
    const config = parsed_config.value;
    var step_number: u64 = try eventCount(allocator, &store);
    var iterations: u32 = 0;
    while (iterations < config.scheduler.max_total_steps) : (iterations += 1) {
        const outcome = try executeStep(allocator, &store, config, step_number + 1);
        step_number += 1;
        if (single_step or outcome != .progressed) return outcome;
    }
    return error.MaximumStepsReached;
}

fn executeStep(allocator: std.mem.Allocator, store: *const Store, config: config_module.Config, step: u64) !Outcome {
    var parsed_dag = try dag_module.load(allocator, store);
    defer parsed_dag.deinit();
    var dag = parsed_dag.value;
    try dag_module.validate(dag);
    const node_index = dag_module.nextRunnable(dag) orelse return terminalOutcome(dag);
    const nodes = @constCast(dag.nodes);
    var node = &nodes[node_index];
    if (node.status == .pending) node.status = .ready;
    try dag_module.transition(node.status, .running);
    node.status = .running;
    try dag_module.save(allocator, store, dag);
    const task_data = try store.readAlloc("task.json", 4 * 1024 * 1024);
    defer allocator.free(task_data);
    var task_parsed = try std.json.parseFromSlice(state.Task, allocator, task_data, .{ .ignore_unknown_fields = false });
    defer task_parsed.deinit();
    const node_json = try json_util.stringifyCompactAlloc(allocator, node.*);
    defer allocator.free(node_json);
    const tool_names = try registry.enabledNames(allocator, config);
    defer allocator.free(tool_names);
    const snapshot = try context_builder.build(allocator, store, config, .{ .step = step, .objective = task_parsed.value.objective, .active_node_json = node_json, .tools = tool_names });
    defer context_builder.deinitSnapshot(allocator, snapshot);
    const log_directory = try std.fs.path.join(allocator, &.{ store.root, "logs/llm" });
    defer allocator.free(log_directory);
    var llm_client = openai.Client{ .allocator = allocator, .config = config.llm, .log_directory = log_directory };
    var action_parsed = if (node.assigned_agent == .coordinator) try coordinator.decide(allocator, &llm_client, snapshot.content) else try domain.decide(allocator, &llm_client, snapshot.content);
    defer action_parsed.deinit();
    const action = action_parsed.value;
    const event_id = try ids.generate(allocator, "event");
    defer allocator.free(event_id);
    var output_ref: ?[]u8 = null;
    defer if (output_ref) |value| allocator.free(value);
    var result_status: events.Status = .succeeded;
    var outcome: Outcome = .progressed;
    executeAction(allocator, store, config, &llm_client, &dag, node_index, action, event_id, &output_ref, &outcome) catch |err| {
        result_status = .failed;
        node.status = if (node.retry_count < config.scheduler.max_retries_per_task) .ready else .failed;
        node.retry_count += 1;
        try dag_module.save(allocator, store, dag);
        try appendEvent(allocator, store, event_id, step, node.*, action.command, snapshot.sha256, result_status, @errorName(err), output_ref);
        try state.pushRecentAction(allocator, store, .{ .step = step, .timestamp = std.time.milliTimestamp(), .actor = @tagName(node.assigned_agent), .action = action.command, .status = "failed", .artifact = output_ref }, config.context.recent_action_window);
        return if (node.status == .failed) .failed else err;
    };
    try dag_module.save(allocator, store, dag);
    try appendEvent(allocator, store, event_id, step, node.*, action.command, snapshot.sha256, result_status, null, output_ref);
    try state.pushRecentAction(allocator, store, .{ .step = step, .timestamp = std.time.milliTimestamp(), .actor = @tagName(node.assigned_agent), .action = action.command, .status = "succeeded", .artifact = output_ref }, config.context.recent_action_window);
    if (step % config.scheduler.consolidation_interval == 0) {
        const path = try consolidation.run(allocator, store, step, config.tools.max_fetched_document_bytes);
        allocator.free(path);
    }
    return outcome;
}

fn executeAction(allocator: std.mem.Allocator, store: *const Store, config: config_module.Config, client: *openai.Client, dag: *dag_module.Dag, node_index: usize, action: @import("llm/client.zig").Action, event_id: []const u8, output: *?[]u8, outcome: *Outcome) !void {
    const nodes = @constCast(dag.nodes);
    const node = &nodes[node_index];
    if (std.mem.eql(u8, action.command, "call_tool")) {
        const tool_value = action.command_args.object.get("tool") orelse return error.InvalidArguments;
        const tool = switch (tool_value) {
            .string => |value| value,
            else => return error.InvalidArguments,
        };
        const args_value = action.command_args.object.get("arguments") orelse return error.InvalidArguments;
        const args = switch (args_value) {
            .object => |value| value,
            else => return error.InvalidArguments,
        };
        output.* = try atomic.invoke(allocator, store, config, client, tool, args);
        if (output.*) |path| if (store.exists(path)) try manifest.update(allocator, store, path, "tool-output", event_id, &.{ tool, node.id }, config.tools.max_fetched_document_bytes);
        node.status = .ready;
    } else if (std.mem.eql(u8, action.command, "mark_done") or std.mem.eql(u8, action.command, "finish")) {
        if (dag_module.hasIncompleteChildren(dag.*, node.id)) return error.AcceptanceFailed;
        for (action.expected_outputs) |path| if (!store.exists(path)) return error.AcceptanceFailed;
        node.status = .done;
        outcome.* = terminalOutcome(dag.*);
    } else if (std.mem.eql(u8, action.command, "fail")) {
        node.status = .failed;
        outcome.* = .failed;
    } else if (std.mem.eql(u8, action.command, "consolidate")) {
        output.* = try consolidation.run(allocator, store, 0, config.tools.max_fetched_document_bytes);
        node.status = .ready;
    } else if (std.mem.eql(u8, action.command, "delegate")) {
        const target_value = action.command_args.object.get("task_node_id") orelse return error.InvalidArguments;
        const target = switch (target_value) {
            .string => |value| value,
            else => return error.InvalidArguments,
        };
        if (!dag_module.canControl(dag.*, node.id, target)) return error.InvalidTransition;
        for (nodes) |*candidate| if (std.mem.eql(u8, candidate.id, target)) {
            if (candidate.status == .pending or candidate.status == .blocked) candidate.status = .ready;
            node.status = .blocked;
            return;
        };
        return error.InvalidArguments;
    } else if (std.mem.eql(u8, action.command, "create_tasks")) {
        try createTasks(allocator, dag, node_index, action.command_args, event_id, config.scheduler.max_recursion_depth);
    } else if (std.mem.eql(u8, action.command, "request_repair")) {
        node.status = .ready;
    } else return error.InvalidArguments;
}

fn createTasks(allocator: std.mem.Allocator, dag: *dag_module.Dag, parent_index: usize, args: std.json.Value, event_id: []const u8, max_depth: u16) !void {
    const task_value = args.object.get("tasks") orelse return error.InvalidArguments;
    const task_array = switch (task_value) {
        .array => |value| value,
        else => return error.InvalidArguments,
    };
    if (task_array.items.len == 0 or task_array.items.len > 32) return error.InvalidArguments;
    const parent = dag.nodes[parent_index];
    if (depth(dag.*, parent.id) >= max_depth) return error.InvalidTransition;
    var expanded = std.ArrayList(dag_module.Node).init(allocator);
    defer expanded.deinit();
    try expanded.appendSlice(dag.nodes);
    for (task_array.items) |value| {
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidArguments,
        };
        const objective = try objectString(object, "objective");
        const agent_name = try objectString(object, "assigned_agent");
        const agent = std.meta.stringToEnum(dag_module.AgentType, agent_name) orelse return error.InvalidArguments;
        const child_id = try ids.generate(allocator, "node");
        const criteria: []const []const u8 = if (object.get("acceptance_criteria")) |criteria_value| blk: {
            const array = switch (criteria_value) {
                .array => |item| item,
                else => return error.InvalidArguments,
            };
            var strings = try allocator.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, index| strings[index] = switch (item) {
                .string => |text| text,
                else => return error.InvalidArguments,
            };
            break :blk strings;
        } else &.{};
        try expanded.append(.{ .id = child_id, .parent_id = parent.id, .status = .ready, .assigned_agent = agent, .objective = objective, .acceptance_criteria = criteria, .creation_event = event_id });
    }
    const owned = try expanded.toOwnedSlice();
    dag.nodes = owned;
    @constCast(dag.nodes)[parent_index].status = .blocked;
}

fn objectString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidArguments;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidArguments,
    };
}

fn depth(dag: dag_module.Dag, id: []const u8) u16 {
    var result: u16 = 0;
    var current = dag_module.find(dag, id);
    while (current) |node| {
        if (node.parent_id) |parent| {
            result += 1;
            current = dag_module.find(dag, parent);
        } else break;
    }
    return result;
}

fn appendEvent(allocator: std.mem.Allocator, store: *const Store, event_id: []const u8, step: u64, node: dag_module.Node, action: []const u8, context_hash: []const u8, status: events.Status, detail: ?[]const u8, output: ?[]const u8) !void {
    const outputs: []const []const u8 = if (output) |value| &.{value} else &.{};
    try events.append(allocator, store, .{ .event_id = event_id, .step = step, .timestamp = std.time.milliTimestamp(), .actor_type = @tagName(node.assigned_agent), .agent_id = node.id, .task_node_id = node.id, .parent_task_node_id = node.parent_id, .action_kind = action, .output_references = outputs, .context_snapshot_hash = context_hash, .status = status, .error_details = detail });
}

fn eventCount(allocator: std.mem.Allocator, store: *const Store) !u64 {
    const data = try store.readAlloc("state/events.jsonl", 256 * 1024 * 1024);
    defer allocator.free(data);
    var count: u64 = 0;
    for (data) |byte| if (byte == '\n') {
        count += 1;
    };
    return count;
}

fn terminalOutcome(dag: dag_module.Dag) Outcome {
    const root = dag_module.find(dag, dag.root_id) orelse return .failed;
    return switch (root.status) {
        .done => .completed,
        .failed, .cancelled => .failed,
        else => .idle,
    };
}
