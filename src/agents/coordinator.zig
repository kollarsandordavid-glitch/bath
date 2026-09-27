const std = @import("std");
const protocol = @import("../llm/client.zig");
const openai = @import("../llm/openai_compatible.zig");
const prompts = @import("../llm/prompts.zig");

pub fn decide(allocator: std.mem.Allocator, client: *openai.Client, context: []const u8) !std.json.Parsed(protocol.Action) {
    const messages = [_]protocol.Message{ .{ .role = "system", .content = prompts.coordinator_system }, .{ .role = "user", .content = context } };
    const response = try client.complete(.{ .messages = &messages });
    defer response.deinit(allocator);
    return protocol.validateAction(allocator, response.content) catch {
        const repair_user = try std.fmt.allocPrint(allocator, "Schema: {{\"rationale_summary\":string,\"command\":enum,\"command_args\":object,\"expected_outputs\":[string],\"acceptance_checks\":[string]}}\nInvalid response:\n{s}", .{response.content});
        defer allocator.free(repair_user);
        const repair_messages = [_]protocol.Message{ .{ .role = "system", .content = prompts.repair_system }, .{ .role = "user", .content = repair_user } };
        const repaired = try client.complete(.{ .messages = &repair_messages });
        defer repaired.deinit(allocator);
        return protocol.validateAction(allocator, repaired.content);
    };
}
