const std = @import("std");

pub const Message = struct { role: []const u8, content: []const u8 };

pub const Request = struct {
    messages: []const Message,
    response_schema_name: []const u8 = "agent_action",
};

pub const Response = struct {
    content: []u8,
    request_id: ?[]u8,
    status_code: u16,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.request_id) |value| allocator.free(value);
    }
};

pub const Action = struct {
    rationale_summary: []const u8,
    command: []const u8,
    command_args: std.json.Value,
    expected_outputs: []const []const u8,
    acceptance_checks: []const []const u8,
};

pub fn validateAction(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(Action) {
    var parsed = std.json.parseFromSlice(Action, allocator, data, .{ .ignore_unknown_fields = false }) catch return error.InvalidLlmResponse;
    errdefer parsed.deinit();
    const action = parsed.value;
    if (action.rationale_summary.len == 0 or action.rationale_summary.len > 4096) return error.InvalidLlmResponse;
    const commands = [_][]const u8{ "create_tasks", "delegate", "call_tool", "consolidate", "mark_done", "request_repair", "finish", "fail" };
    var valid = false;
    for (commands) |command| {
        if (std.mem.eql(u8, command, action.command)) valid = true;
    }
    if (!valid or action.command_args != .object) return error.InvalidLlmResponse;
    if (action.expected_outputs.len > 64 or action.acceptance_checks.len > 64) return error.InvalidLlmResponse;
    return parsed;
}
