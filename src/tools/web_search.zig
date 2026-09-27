const std = @import("std");
const config_module = @import("../config.zig");
const http_fetch = @import("http_fetch.zig");

pub fn search(allocator: std.mem.Allocator, config: config_module.Tools, query: []const u8) ![]u8 {
    for (config.allowed_web_search_providers) |provider| {
        if (std.mem.eql(u8, provider, "searxng")) if (config.searxng_base_url) |base| {
            const escaped = try percentEncode(allocator, query);
            defer allocator.free(escaped);
            const url = try std.fmt.allocPrint(allocator, "{s}/search?q={s}&format=json", .{ std.mem.trimRight(u8, base, "/"), escaped });
            defer allocator.free(url);
            const result = try http_fetch.fetch(allocator, url, config.max_fetched_document_bytes, config.max_redirects);
            defer result.deinit(allocator);
            if (result.status < 200 or result.status >= 300) return error.SearchProviderUnavailable;
            return allocator.dupe(u8, result.raw);
        };
        if (std.mem.eql(u8, provider, "commercial")) if (config.commercial_search_base_url) |base| {
            const key = std.process.getEnvVarOwned(allocator, config.commercial_search_api_key_env) catch continue;
            defer allocator.free(key);
            const escaped = try percentEncode(allocator, query);
            defer allocator.free(escaped);
            const key_escaped = try percentEncode(allocator, key);
            defer allocator.free(key_escaped);
            const url = try std.fmt.allocPrint(allocator, "{s}?q={s}&api_key={s}", .{ base, escaped, key_escaped });
            defer allocator.free(url);
            const result = try http_fetch.fetch(allocator, url, config.max_fetched_document_bytes, config.max_redirects);
            defer result.deinit(allocator);
            if (result.status < 200 or result.status >= 300) return error.SearchProviderUnavailable;
            return allocator.dupe(u8, result.raw);
        };
    }
    return error.SearchProviderUnavailable;
}

fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try output.append(byte) else {
            try output.append('%');
            try output.append(hex[byte >> 4]);
            try output.append(hex[byte & 15]);
        }
    }
    return output.toOwnedSlice();
}
