const std = @import("std");
const Store = @import("../fs_store.zig").Store;
const events = @import("../events.zig");

pub const Metrics = struct {
    completed: bool,
    step_count: usize,
    llm_calls: usize,
    tool_calls: usize,
    failures: usize,
    context_bytes_per_step: []const usize,
    evaluator_overall: ?f64 = null,
};

pub fn collect(allocator: std.mem.Allocator, workspace: []const u8) !Metrics {
    var store = try Store.init(allocator, workspace);
    defer store.deinit();
    var replayed = try events.replay(allocator, &store, 256 * 1024 * 1024);
    defer {
        for (replayed.items) |event| events.freeEvent(allocator, event);
        replayed.deinit();
    }
    var llm_calls: usize = 0;
    var tool_calls: usize = 0;
    var failures: usize = 0;
    for (replayed.items) |event| {
        if (event.llm_call_id != null) llm_calls += 1;
        if (event.tool_call_id != null or std.mem.eql(u8, event.action_kind, "call_tool")) tool_calls += 1;
        if (event.status == .failed) failures += 1;
    }
    var sizes = std.ArrayList(usize).init(allocator);
    errdefer sizes.deinit();
    const history = try store.absolutePath("state/context/history");
    defer allocator.free(history);
    var directory = try std.fs.openDirAbsolute(history, .{ .iterate = true });
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| if (entry.kind == .file) {
        const file = try directory.openFile(entry.name, .{});
        defer file.close();
        const stat = try file.stat();
        try sizes.append(@intCast(stat.size));
    };
    const task_data = try store.readAlloc("task.json", 4 * 1024 * 1024);
    defer allocator.free(task_data);
    const completed = std.mem.indexOf(u8, task_data, "\"status\": \"done\"") != null or store.exists("artifacts/reports/final.md");
    return .{ .completed = completed, .step_count = replayed.items.len, .llm_calls = llm_calls, .tool_calls = tool_calls, .failures = failures, .context_bytes_per_step = try sizes.toOwnedSlice() };
}

pub fn aggregate(allocator: std.mem.Allocator, values: []const Metrics) ![]u8 {
    var completed: usize = 0;
    var steps: usize = 0;
    var llm: usize = 0;
    var tools: usize = 0;
    var failures: usize = 0;
    for (values) |value| {
        if (value.completed) completed += 1;
        steps += value.step_count;
        llm += value.llm_calls;
        tools += value.tool_calls;
        failures += value.failures;
    }
    const rate: f64 = if (values.len == 0) 0 else @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(values.len));
    return std.fmt.allocPrint(allocator, "{{\"runs\":{d},\"completion_rate\":{d:.6},\"step_count\":{d},\"llm_calls\":{d},\"tool_calls\":{d},\"failures\":{d}}}", .{ values.len, rate, steps, llm, tools, failures });
}
