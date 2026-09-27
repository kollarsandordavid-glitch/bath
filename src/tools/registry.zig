const std = @import("std");
const config_module = @import("../config.zig");

pub const Kind = enum { file_read, file_write, file_list, file_search, web_search, http_fetch, document_ingest, document_answer, code_exec };

pub const Descriptor = struct { name: []const u8, kind: Kind, description: []const u8 };

pub const descriptors = [_]Descriptor{
    .{ .name = "file-read", .kind = .file_read, .description = "Read a bounded workspace file" },
    .{ .name = "file-write", .kind = .file_write, .description = "Atomically write an artifact or state file" },
    .{ .name = "file-list", .kind = .file_list, .description = "List a workspace directory deterministically" },
    .{ .name = "file-search", .kind = .file_search, .description = "Search bounded workspace files" },
    .{ .name = "web-search", .kind = .web_search, .description = "Query a configured real search provider" },
    .{ .name = "http-fetch", .kind = .http_fetch, .description = "Fetch and extract a real HTTP resource" },
    .{ .name = "document-ingest", .kind = .document_ingest, .description = "Ingest and chunk a local document" },
    .{ .name = "document-answer", .kind = .document_answer, .description = "Rank document chunks and answer with evidence" },
    .{ .name = "code-exec", .kind = .code_exec, .description = "Execute an allowlisted program inside the configured workspace sandbox" },
};

pub fn lookup(config: config_module.Config, name: []const u8) !Descriptor {
    if (!config_module.isToolEnabled(config, name) and !(std.mem.eql(u8, name, "code-exec") and config.tools.code_execution.enabled)) return error.ToolDisabled;
    for (descriptors) |descriptor| if (std.mem.eql(u8, descriptor.name, name)) return descriptor;
    return error.UnknownTool;
}

pub fn enabledNames(allocator: std.mem.Allocator, config: config_module.Config) ![][]const u8 {
    var names = std.ArrayList([]const u8).init(allocator);
    errdefer names.deinit();
    for (descriptors) |descriptor| {
        if (config_module.isToolEnabled(config, descriptor.name) or (descriptor.kind == .code_exec and config.tools.code_execution.enabled)) try names.append(descriptor.name);
    }
    return names.toOwnedSlice();
}
