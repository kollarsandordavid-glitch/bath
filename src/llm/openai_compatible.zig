const std = @import("std");
const config_module = @import("../config.zig");
const json_util = @import("../json_util.zig");
const protocol = @import("client.zig");

const ApiMessage = struct { role: []const u8, content: []const u8 };
const ResponseFormat = struct { type: []const u8 = "json_object" };
const ApiRequest = struct {
    model: []const u8,
    messages: []const ApiMessage,
    temperature: f64,
    max_tokens: u32,
    response_format: ResponseFormat = .{},
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: config_module.Llm,
    log_directory: []const u8,

    pub fn complete(self: *Client, request: protocol.Request) !protocol.Response {
        const api_key = std.process.getEnvVarOwned(self.allocator, self.config.api_key_env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.MissingApiKey,
            else => return err,
        };
        defer self.allocator.free(api_key);
        var messages = try self.allocator.alloc(ApiMessage, request.messages.len);
        defer self.allocator.free(messages);
        for (request.messages, 0..) |message, index| messages[index] = .{ .role = message.role, .content = message.content };
        const body = try json_util.stringifyCompactAlloc(self.allocator, ApiRequest{
            .model = self.config.model,
            .messages = messages,
            .temperature = self.config.temperature,
            .max_tokens = self.config.max_output_tokens,
        });
        defer self.allocator.free(body);
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{std.mem.trimRight(u8, self.config.base_url, "/")});
        defer self.allocator.free(endpoint);
        try self.logRequest(endpoint, body);
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const response = self.requestOnce(endpoint, api_key, body) catch |err| {
                if (attempt >= self.config.retry_count) return err;
                std.Thread.sleep(backoffNanos(self.config, attempt));
                continue;
            };
            return response;
        }
    }

    fn requestOnce(self: *Client, endpoint: []const u8, api_key: []const u8, body: []const u8) !protocol.Response {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        var response_body = std.ArrayList(u8).init(self.allocator);
        errdefer response_body.deinit();
        const authorization = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
        defer self.allocator.free(authorization);
        const result = client.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = body,
            .response_storage = .{ .dynamic = &response_body },
            .max_append_size = 16 * 1024 * 1024,
            .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = authorization }, .accept_encoding = .omit },
            .keep_alive = false,
        }) catch return error.ProviderFailure;
        const status: u16 = @intFromEnum(result.status);
        try self.logResponse(status, response_body.items);
        if (status == 401 or status == 403) return error.ProviderUnauthorized;
        if (status == 429) return error.ProviderRateLimited;
        if (status < 200 or status >= 300) return error.ProviderFailure;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body.items, .{}) catch return error.InvalidLlmResponse;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidLlmResponse,
        };
        const choices_value = root.get("choices") orelse return error.InvalidLlmResponse;
        const choices = switch (choices_value) {
            .array => |value| value,
            else => return error.InvalidLlmResponse,
        };
        if (choices.items.len == 0) return error.InvalidLlmResponse;
        const choice = switch (choices.items[0]) {
            .object => |value| value,
            else => return error.InvalidLlmResponse,
        };
        const message_value = choice.get("message") orelse return error.InvalidLlmResponse;
        const message = switch (message_value) {
            .object => |value| value,
            else => return error.InvalidLlmResponse,
        };
        const content_value = message.get("content") orelse return error.InvalidLlmResponse;
        const content = switch (content_value) {
            .string => |value| value,
            else => return error.InvalidLlmResponse,
        };
        const request_id: ?[]u8 = if (root.get("id")) |identifier| switch (identifier) {
            .string => |value| try self.allocator.dupe(u8, value),
            else => null,
        } else null;
        return .{ .content = try self.allocator.dupe(u8, content), .request_id = request_id, .status_code = status };
    }

    fn logRequest(self: *Client, endpoint: []const u8, body: []const u8) !void {
        try std.fs.cwd().makePath(self.log_directory);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/request-{d}.json", .{ self.log_directory, std.time.milliTimestamp() });
        defer self.allocator.free(path);
        const record = try std.fmt.allocPrint(self.allocator, "{{\"endpoint\":{f},\"body\":{s}}}\n", .{ std.json.fmt(endpoint, .{}), body });
        defer self.allocator.free(record);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(record);
    }

    fn logResponse(self: *Client, status: u16, body: []const u8) !void {
        try std.fs.cwd().makePath(self.log_directory);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/response-{d}.json", .{ self.log_directory, std.time.milliTimestamp() });
        defer self.allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writer().print("{{\"status\":{d},\"body\":", .{status});
        try std.json.stringify(body, .{}, file.writer());
        try file.writeAll("}\n");
    }
};

fn backoffNanos(config: config_module.Llm, attempt: u8) u64 {
    const factor: u64 = switch (config.backoff_policy) {
        .linear => @as(u64, attempt) + 1,
        .exponential => @as(u64, 1) << @min(attempt, 16),
    };
    return config.initial_backoff_ms * factor * std.time.ns_per_ms;
}
