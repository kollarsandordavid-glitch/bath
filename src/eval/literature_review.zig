const std = @import("std");
const config_module = @import("../config.zig");
const Store = @import("../fs_store.zig").Store;
const external = @import("../external_attention.zig");
const openai = @import("../llm/openai_compatible.zig");

const Paper = struct { id: []const u8, title: []const u8, path: ?[]const u8 = null, url: ?[]const u8 = null };

pub fn run(allocator: std.mem.Allocator, config_path: []const u8, papers_path: []const u8, topic_path: []const u8, output_directory: []const u8) !void {
    var config_parsed = try config_module.load(allocator, config_path);
    defer config_parsed.deinit();
    const topic_file = try std.fs.cwd().openFile(topic_path, .{});
    defer topic_file.close();
    const topic = try topic_file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(topic);
    try std.fs.cwd().makePath(output_directory);
    var store = try Store.init(allocator, output_directory);
    defer store.deinit();
    const papers_file = try std.fs.cwd().openFile(papers_path, .{});
    defer papers_file.close();
    const data = try papers_file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(data);
    const log_directory = try std.fs.path.join(allocator, &.{ store.root, "logs/llm" });
    defer allocator.free(log_directory);
    try std.fs.cwd().makePath(log_directory);
    var client = openai.Client{ .allocator = allocator, .config = config_parsed.value.llm, .log_directory = log_directory };
    var report = std.ArrayList(u8).init(allocator);
    defer report.deinit();
    try report.appendSlice("# Literature Review\n\n| Paper | Evidence Artifact | Relevance |\n| --- | --- | --- |\n");
    var lines = std.mem.splitScalar(u8, data, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        if (count >= 80) break;
        var paper = try std.json.parseFromSlice(Paper, allocator, line, .{ .ignore_unknown_fields = false });
        defer paper.deinit();
        const source = paper.value.path orelse return error.InvalidArguments;
        const document_id = try external.ingest(allocator, &store, config_parsed.value, source);
        defer allocator.free(document_id);
        const query = try std.fmt.allocPrint(allocator, "For the review topic below, summarize methods, findings, limitations, open questions, and assess relevance on a 0-5 rubric where 0 is unrelated and 5 directly answers the topic. Topic: {s}", .{topic});
        defer allocator.free(query);
        const answer_path = try external.answer(allocator, &store, config_parsed.value, &client, document_id, query);
        defer allocator.free(answer_path);
        try report.writer().print("| {s} | `{s}` | Recorded in evidence artifact |\n", .{ paper.value.title, answer_path });
        count += 1;
    }
    try report.writer().print("\nProcessed {d} papers. Detailed methods, findings, limitations, open questions, citations, and rubric scores are preserved in the per-paper answer artifacts and must be synthesized from those persistent files.\n", .{count});
    try store.makePath("artifacts/reports");
    try store.atomicWrite("artifacts/reports/literature-review.md", report.items);
}
