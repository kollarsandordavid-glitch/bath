const std = @import("std");
const Store = @import("../fs_store.zig").Store;
const ids = @import("../ids.zig");
const json_util = @import("../json_util.zig");
const manifest = @import("../manifest.zig");

pub const Chunk = struct {
    id: []const u8,
    source: []const u8,
    page: ?u32,
    byte_start: usize,
    byte_end: usize,
    sha256: []const u8,
    path: []const u8,
};

pub const Index = struct {
    document_id: []const u8,
    source_path: []const u8,
    source_sha256: []const u8,
    extracted_at: i64,
    chunks: []const Chunk,
};

pub fn ingest(allocator: std.mem.Allocator, store: *const Store, source_path: []const u8, extractor: []const u8, max_bytes: usize) ![]u8 {
    const source = try std.fs.cwd().openFile(source_path, .{});
    defer source.close();
    const stat = try source.stat();
    if (stat.size > max_bytes) return error.FileTooLarge;
    const source_data = try source.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(source_data);
    const document_id = try ids.generate(allocator, "doc");
    errdefer allocator.free(document_id);
    const extension = std.fs.path.extension(source_path);
    const source_relative = try std.fmt.allocPrint(allocator, "artifacts/documents/{s}{s}", .{ document_id, extension });
    defer allocator.free(source_relative);
    try store.atomicWrite(source_relative, source_data);
    const extracted = if (std.ascii.eqlIgnoreCase(extension, ".pdf"))
        try extractPdf(allocator, store, source_relative, extractor, max_bytes)
    else if (std.ascii.eqlIgnoreCase(extension, ".txt") or std.ascii.eqlIgnoreCase(extension, ".md"))
        try allocator.dupe(u8, source_data)
    else if (std.ascii.eqlIgnoreCase(extension, ".html") or std.ascii.eqlIgnoreCase(extension, ".htm"))
        try @import("http_fetch.zig").htmlToText(allocator, source_data)
    else
        return error.ExtractionFailed;
    defer allocator.free(extracted);
    const source_hash = try store.hashHexAlloc(source_data);
    defer allocator.free(source_hash);
    var chunks = std.ArrayList(Chunk).init(allocator);
    defer {
        for (chunks.items) |chunk| {
            allocator.free(chunk.id);
            allocator.free(chunk.source);
            allocator.free(chunk.sha256);
            allocator.free(chunk.path);
        }
        chunks.deinit();
    }
    var start: usize = 0;
    var number: usize = 0;
    while (start < extracted.len) : (number += 1) {
        var end = @min(start + 4096, extracted.len);
        if (end < extracted.len) if (std.mem.lastIndexOfScalar(u8, extracted[start..end], '\n')) |newline| if (newline > 1024) {
            end = start + newline + 1;
        };
        const content = extracted[start..end];
        const chunk_id = try std.fmt.allocPrint(allocator, "chunk-{d}", .{number});
        const chunk_path = try std.fmt.allocPrint(allocator, "artifacts/extracted_text/{s}-{s}.txt", .{ document_id, chunk_id });
        try store.atomicWrite(chunk_path, content);
        const hash = try store.hashHexAlloc(content);
        try chunks.append(.{ .id = chunk_id, .source = try allocator.dupe(u8, source_path), .page = pageNumber(extracted, start), .byte_start = start, .byte_end = end, .sha256 = hash, .path = chunk_path });
        try manifest.update(allocator, store, chunk_path, "document-chunk", null, &.{ "document", document_id }, max_bytes);
        start = end;
    }
    const index = Index{ .document_id = document_id, .source_path = source_path, .source_sha256 = source_hash, .extracted_at = std.time.milliTimestamp(), .chunks = chunks.items };
    const index_json = try json_util.stringifyAlloc(allocator, index);
    defer allocator.free(index_json);
    const index_path = try std.fmt.allocPrint(allocator, "artifacts/extracted_text/{s}.index.json", .{document_id});
    defer allocator.free(index_path);
    try store.atomicWrite(index_path, index_json);
    try manifest.update(allocator, store, source_relative, "source-document", null, &.{"document"}, max_bytes);
    try manifest.update(allocator, store, index_path, "document-index", null, &.{ "document-index", document_id }, max_bytes);
    return document_id;
}

fn extractPdf(allocator: std.mem.Allocator, store: *const Store, relative: []const u8, extractor: []const u8, max_bytes: usize) ![]u8 {
    const input = try store.absolutePath(relative);
    defer allocator.free(input);
    const output = try std.fmt.allocPrint(allocator, "{s}.txt", .{input});
    defer allocator.free(output);
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ extractor, "-layout", input, output }, .max_output_bytes = 1024 * 1024 }) catch |err| switch (err) {
        error.FileNotFound => return error.ExtractorUnavailable,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const successful = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!successful) return error.ExtractionFailed;
    defer std.fs.deleteFileAbsolute(output) catch {};
    const file = try std.fs.openFileAbsolute(output, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn pageNumber(text: []const u8, offset: usize) ?u32 {
    var page: u32 = 1;
    for (text[0..offset]) |byte| if (byte == 12) {
        page += 1;
    };
    return page;
}
