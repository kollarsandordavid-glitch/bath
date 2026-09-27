const std = @import("std");

pub const FetchResult = struct {
    status: u16,
    raw: []u8,
    text: []u8,

    pub fn deinit(self: FetchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
        allocator.free(self.text);
    }
};

pub fn fetch(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize, max_redirects: u8) !FetchResult {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return error.InvalidPath;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = max_bytes,
        .redirect_behavior = @enumFromInt(max_redirects),
        .headers = .{ .accept_encoding = .omit, .user_agent = .{ .override = "long-horizon-agent/1.0" } },
        .keep_alive = false,
    });
    const raw = try body.toOwnedSlice();
    errdefer allocator.free(raw);
    const text = try htmlToText(allocator, raw);
    return .{ .status = @intFromEnum(response.status), .raw = raw, .text = text };
}

pub fn htmlToText(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var index: usize = 0;
    var in_tag = false;
    var suppressed_depth: usize = 0;
    while (index < input.len) {
        if (input[index] == '<') {
            const close = std.mem.indexOfScalarPos(u8, input, index, '>') orelse break;
            const tag_raw = std.mem.trim(u8, input[index + 1 .. close], " \t\r\n");
            const closing = tag_raw.len > 0 and tag_raw[0] == '/';
            const name_start: usize = if (closing) 1 else 0;
            var name_end = name_start;
            while (name_end < tag_raw.len and std.ascii.isAlphabetic(tag_raw[name_end])) name_end += 1;
            const name = tag_raw[name_start..name_end];
            if (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style") or std.ascii.eqlIgnoreCase(name, "noscript")) {
                if (closing) {
                    if (suppressed_depth > 0) suppressed_depth -= 1;
                } else suppressed_depth += 1;
            }
            if (suppressed_depth == 0 and (std.ascii.eqlIgnoreCase(name, "p") or std.ascii.eqlIgnoreCase(name, "br") or std.ascii.eqlIgnoreCase(name, "div") or std.ascii.eqlIgnoreCase(name, "li") or std.ascii.eqlIgnoreCase(name, "h1") or std.ascii.eqlIgnoreCase(name, "h2") or std.ascii.eqlIgnoreCase(name, "h3"))) try appendSpace(&output);
            index = close + 1;
            in_tag = false;
            continue;
        }
        if (!in_tag and suppressed_depth == 0) {
            if (input[index] == '&') {
                if (std.mem.startsWith(u8, input[index..], "&amp;")) {
                    try output.append('&');
                    index += 5;
                    continue;
                }
                if (std.mem.startsWith(u8, input[index..], "&lt;")) {
                    try output.append('<');
                    index += 4;
                    continue;
                }
                if (std.mem.startsWith(u8, input[index..], "&gt;")) {
                    try output.append('>');
                    index += 4;
                    continue;
                }
                if (std.mem.startsWith(u8, input[index..], "&quot;")) {
                    try output.append('"');
                    index += 6;
                    continue;
                }
                if (std.mem.startsWith(u8, input[index..], "&#39;")) {
                    try output.append('\'');
                    index += 5;
                    continue;
                }
            }
            if (std.ascii.isWhitespace(input[index])) try appendSpace(&output) else try output.append(input[index]);
        }
        index += 1;
    }
    return output.toOwnedSlice();
}

fn appendSpace(output: *std.ArrayList(u8)) !void {
    if (output.items.len > 0 and output.items[output.items.len - 1] != ' ') try output.append(' ');
}
