const std = @import("std");
const config_module = @import("config.zig");
const Store = @import("fs_store.zig").Store;
const state = @import("state.zig");
const scheduler = @import("scheduler.zig");
const consolidation = @import("consolidation.zig");
const external = @import("external_attention.zig");
const openai = @import("llm/openai_compatible.zig");
const deepresearch = @import("eval/deepresearch.zig");
const literature = @import("eval/literature_review.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2 or std.mem.eql(u8, args[1], "help")) return printHelp();
    const command = args[1];
    if (std.mem.eql(u8, command, "init")) {
        const workspace = try option(args, "--workspace");
        const objective_path = try option(args, "--objective-file");
        const config_path = try option(args, "--config");
        var parsed_config = try config_module.load(allocator, config_path);
        defer parsed_config.deinit();
        const objective_file = try std.fs.cwd().openFile(objective_path, .{});
        defer objective_file.close();
        const objective = try objective_file.readToEndAlloc(allocator, 4 * 1024 * 1024);
        defer allocator.free(objective);
        try state.initialize(allocator, workspace, objective, parsed_config.value);
    } else if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "resume") or std.mem.eql(u8, command, "step")) {
        const outcome = try scheduler.run(allocator, try option(args, "--workspace"), std.mem.eql(u8, command, "step"));
        try std.io.getStdOut().writer().print("{s}\n", .{@tagName(outcome)});
    } else if (std.mem.eql(u8, command, "status")) {
        const workspace = try option(args, "--workspace");
        var store = try Store.init(allocator, workspace);
        defer store.deinit();
        const task = try store.readAlloc("task.json", 4 * 1024 * 1024);
        defer allocator.free(task);
        const dag = try store.readAlloc("tasks/dag.json", 16 * 1024 * 1024);
        defer allocator.free(dag);
        if (hasFlag(args, "--json")) try std.io.getStdOut().writer().print("{{\"task\":{s},\"dag\":{s}}}\n", .{ task, dag }) else try std.io.getStdOut().writer().print("Task\n{s}\nDAG\n{s}\n", .{ task, dag });
    } else if (std.mem.eql(u8, command, "inspect-context")) {
        var store = try Store.init(allocator, try option(args, "--workspace"));
        defer store.deinit();
        const context = try store.readAlloc("state/context/current.md", 64 * 1024 * 1024);
        defer allocator.free(context);
        try std.io.getStdOut().writeAll(context);
    } else if (std.mem.eql(u8, command, "consolidate")) {
        var store = try Store.init(allocator, try option(args, "--workspace"));
        defer store.deinit();
        const path = try consolidation.run(allocator, &store, 0, 256 * 1024 * 1024);
        defer allocator.free(path);
        try std.io.getStdOut().writer().print("{s}\n", .{path});
    } else if (std.mem.eql(u8, command, "tool")) {
        try runTool(allocator, args);
    } else if (std.mem.eql(u8, command, "eval")) {
        try runEval(allocator, args);
    } else return error.InvalidArguments;
}

fn runTool(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) return error.InvalidArguments;
    const workspace = try option(args, "--workspace");
    var store = try Store.init(allocator, workspace);
    defer store.deinit();
    const config_path = try store.absolutePath("config.resolved.json");
    defer allocator.free(config_path);
    var config = try config_module.load(allocator, config_path);
    defer config.deinit();
    if (std.mem.eql(u8, args[2], "document-ingest")) {
        const id = try external.ingest(allocator, &store, config.value, try option(args, "--path"));
        defer allocator.free(id);
        try std.io.getStdOut().writer().print("{s}\n", .{id});
    } else if (std.mem.eql(u8, args[2], "document-answer")) {
        const log_dir = try std.fs.path.join(allocator, &.{ store.root, "logs/llm" });
        defer allocator.free(log_dir);
        var client = openai.Client{ .allocator = allocator, .config = config.value.llm, .log_directory = log_dir };
        const path = try external.answer(allocator, &store, config.value, &client, try option(args, "--document"), try option(args, "--query"));
        defer allocator.free(path);
        try std.io.getStdOut().writer().print("{s}\n", .{path});
    } else return error.UnknownTool;
}

fn runEval(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) return error.InvalidArguments;
    if (std.mem.eql(u8, args[2], "deepresearch")) try deepresearch.run(allocator, try option(args, "--config"), try option(args, "--tasks"), try option(args, "--out")) else if (std.mem.eql(u8, args[2], "literature-review")) try literature.run(allocator, try option(args, "--config"), try option(args, "--papers"), try option(args, "--topic"), try option(args, "--out")) else return error.InvalidArguments;
}

pub fn option(args: []const []const u8, name: []const u8) ![]const u8 {
    for (args, 0..) |argument, index| if (std.mem.eql(u8, argument, name)) {
        if (index + 1 >= args.len) return error.InvalidArguments;
        return args[index + 1];
    };
    return error.InvalidArguments;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |argument| if (std.mem.eql(u8, argument, name)) return true;
    return false;
}

fn printHelp() void {
    std.io.getStdOut().writeAll("long-horizon-agent init --workspace PATH --objective-file FILE --config FILE\nlong-horizon-agent run|resume|step --workspace PATH\nlong-horizon-agent status --workspace PATH [--json]\nlong-horizon-agent inspect-context|consolidate --workspace PATH\nlong-horizon-agent tool document-ingest --workspace PATH --path FILE\nlong-horizon-agent tool document-answer --workspace PATH --document DOC --query QUERY\nlong-horizon-agent eval deepresearch --config FILE --tasks FILE --out DIR\nlong-horizon-agent eval literature-review --config FILE --papers FILE --topic FILE --out DIR\n") catch {};
}
