const std = @import("std");
const Store = @import("fs_store.zig").Store;
const Config = @import("config.zig").Config;
const ingest_module = @import("tools/document_ingest.zig");
const answer_module = @import("tools/document_answer.zig");
const openai = @import("llm/openai_compatible.zig");

pub fn ingest(allocator: std.mem.Allocator, store: *const Store, config: Config, path: []const u8) ![]u8 {
    return ingest_module.ingest(allocator, store, path, config.tools.pdf_extraction_command, config.tools.max_fetched_document_bytes);
}

pub fn answer(allocator: std.mem.Allocator, store: *const Store, config: Config, client: *openai.Client, document: []const u8, query: []const u8) ![]u8 {
    return answer_module.answer(allocator, store, document, query, config.context.document_answer_context_bytes, client, config.tools.max_fetched_document_bytes);
}
