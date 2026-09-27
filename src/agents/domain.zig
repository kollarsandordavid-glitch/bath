const std = @import("std");
const protocol = @import("../llm/client.zig");
const openai = @import("../llm/openai_compatible.zig");
const prompts = @import("../llm/prompts.zig");

pub const CompletionRecord = struct {
    task_node_id: []const u8,
    status: []const u8,
    output_artifacts: []const []const u8,
    acceptance_evidence: []const []const u8,
};

pub fn decide(allocator: std.mem.Allocator, client: *openai.Client, context: []const u8) !std.json.Parsed(protocol.Action) {
    const messages = [_]protocol.Message{ .{ .role = "system", .content = prompts.domain_system }, .{ .role = "user", .content = context } };
    const response = try client.complete(.{ .messages = &messages });
    defer response.deinit(allocator);
    return protocol.validateAction(allocator, response.content) catch {
        const repair_messages = [_]protocol.Message{ .{ .role = "system", .content = prompts.repair_system }, .{ .role = "user", .content = response.content } };
        const repaired = try client.complete(.{ .messages = &repair_messages });
        defer repaired.deinit(allocator);
        return protocol.validateAction(allocator, repaired.content);
    };
}
