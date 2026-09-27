const std = @import("std");
const config_module = @import("../config.zig");
const state = @import("../state.zig");
const scheduler = @import("../scheduler.zig");
const metrics_module = @import("metrics.zig");

const BenchmarkTask = struct { id: []const u8, objective: []const u8 };

pub fn run(allocator: std.mem.Allocator, config_path: []const u8, tasks_path: []const u8, output_directory: []const u8) !void {
    var config_parsed = try config_module.load(allocator, config_path);
    defer config_parsed.deinit();
    try std.fs.cwd().makePath(output_directory);
    const file = try std.fs.cwd().openFile(tasks_path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(data);
    var all_metrics = std.ArrayList(metrics_module.Metrics).init(allocator);
    defer {
        for (all_metrics.items) |metric| allocator.free(metric.context_bytes_per_step);
        all_metrics.deinit();
    }
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var task = try std.json.parseFromSlice(BenchmarkTask, allocator, line, .{ .ignore_unknown_fields = false });
        defer task.deinit();
        var repeat: u16 = 0;
        while (repeat < config_parsed.value.evaluation.repeated_run_count) : (repeat += 1) {
            const workspace = try std.fmt.allocPrint(allocator, "{s}/{s}-run-{d}", .{ output_directory, task.value.id, repeat + 1 });
            defer allocator.free(workspace);
            var run_config = config_parsed.value;
            run_config.workspace_root = workspace;
            try state.initialize(allocator, workspace, task.value.objective, run_config);
            _ = scheduler.run(allocator, workspace, false) catch |err| switch (err) {
                error.MaximumStepsReached, error.ProviderFailure, error.MissingApiKey, error.ProviderUnauthorized, error.ProviderRateLimited => {},
                else => return err,
            };
            try all_metrics.append(try metrics_module.collect(allocator, workspace));
        }
    }
    const aggregate = try metrics_module.aggregate(allocator, all_metrics.items);
    defer allocator.free(aggregate);
    const json_path = try std.fs.path.join(allocator, &.{ output_directory, "aggregate.json" });
    defer allocator.free(json_path);
    const json_file = try std.fs.cwd().createFile(json_path, .{});
    defer json_file.close();
    try json_file.writeAll(aggregate);
    const markdown_path = try std.fs.path.join(allocator, &.{ output_directory, "aggregate.md" });
    defer allocator.free(markdown_path);
    const markdown = try std.fmt.allocPrint(allocator, "# DeepResearch Evaluation\n\nReal run metrics are stored in `aggregate.json`.\n\n```json\n{s}\n```\n", .{aggregate});
    defer allocator.free(markdown);
    const markdown_file = try std.fs.cwd().createFile(markdown_path, .{});
    defer markdown_file.close();
    try markdown_file.writeAll(markdown);
}
