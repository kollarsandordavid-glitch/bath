const std = @import("std");
const Store = @import("../fs_store.zig").Store;
const config_module = @import("../config.zig");
const registry = @import("../tools/registry.zig");
const file_tools = @import("../tools/file_tools.zig");
const web_search = @import("../tools/web_search.zig");
const http_fetch = @import("../tools/http_fetch.zig");
const document_ingest = @import("../tools/document_ingest.zig");
const document_answer = @import("../tools/document_answer.zig");
const code_exec = @import("../tools/code_exec.zig");
const openai = @import("../llm/openai_compatible.zig");

pub fn invoke(allocator: std.mem.Allocator, store: *const Store, config: config_module.Config, client: *openai.Client, name: []const u8, arguments: std.json.ObjectMap) ![]u8 {
    const descriptor = try registry.lookup(config, name);
    return switch (descriptor.kind) {
        .file_read => file_tools.read(store, try stringArg(arguments, "path"), config.tools.max_fetched_document_bytes),
        .file_write => blk: {
            const path = try stringArg(arguments, "path");
            const content = try stringArg(arguments, "content");
            try file_tools.write(store, path, content);
            break :blk allocator.dupe(u8, path);
        },
        .file_list => file_tools.list(allocator, store, try stringArg(arguments, "path"), config.context.max_workspace_index_entries),
        .file_search => file_tools.search(allocator, store, try stringArg(arguments, "path"), try stringArg(arguments, "query"), config.tools.max_fetched_document_bytes, config.context.max_workspace_index_entries),
        .web_search => web_search.search(allocator, config.tools, try stringArg(arguments, "query")),
        .http_fetch => blk: {
            const result = try http_fetch.fetch(allocator, try stringArg(arguments, "url"), config.tools.max_fetched_document_bytes, config.tools.max_redirects);
            defer result.deinit(allocator);
            break :blk allocator.dupe(u8, result.text);
        },
        .document_ingest => document_ingest.ingest(allocator, store, try stringArg(arguments, "path"), config.tools.pdf_extraction_command, config.tools.max_fetched_document_bytes),
        .document_answer => document_answer.answer(allocator, store, try stringArg(arguments, "document"), try stringArg(arguments, "query"), config.context.document_answer_context_bytes, client, config.tools.max_fetched_document_bytes),
        .code_exec => blk: {
            const argv_value = arguments.get("argv") orelse return error.InvalidArguments;
            const array = switch (argv_value) {
                .array => |value| value,
                else => return error.InvalidArguments,
            };
            var argv = try allocator.alloc([]const u8, array.items.len);
            defer allocator.free(argv);
            for (array.items, 0..) |value, index| argv[index] = switch (value) {
                .string => |string| string,
                else => return error.InvalidArguments,
            };
            break :blk code_exec.execute(allocator, store, config.tools.code_execution, argv);
        },
    };
}

fn stringArg(arguments: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = arguments.get(name) orelse return error.InvalidArguments;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidArguments,
    };
}
