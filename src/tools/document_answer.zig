const std = @import("std");
const Store = @import("../fs_store.zig").Store;
const ingest = @import("document_ingest.zig");
const protocol = @import("../llm/client.zig");
const openai = @import("../llm/openai_compatible.zig");
const prompts = @import("../llm/prompts.zig");
const ids = @import("../ids.zig");
const manifest = @import("../manifest.zig");

pub const RankedChunk = struct { index: usize, score: f64 };

pub fn rank(allocator: std.mem.Allocator, query: []const u8, chunks: []const []const u8) ![]RankedChunk {
    var query_terms = try tokenize(allocator, query);
    defer freeTokens(allocator, &query_terms);
    var document_terms = try allocator.alloc(std.ArrayList([]u8), chunks.len);
    defer {
        for (document_terms) |*terms| freeTokens(allocator, terms);
        allocator.free(document_terms);
    }
    var total_length: usize = 0;
    for (chunks, 0..) |chunk, index| {
        document_terms[index] = try tokenize(allocator, chunk);
        total_length += document_terms[index].items.len;
    }
    const average_length: f64 = if (chunks.len == 0) 1 else @as(f64, @floatFromInt(total_length)) / @as(f64, @floatFromInt(chunks.len));
    var results = try allocator.alloc(RankedChunk, chunks.len);
    for (chunks, 0..) |_, index| {
        var score: f64 = 0;
        for (query_terms.items) |term| {
            var document_frequency: usize = 0;
            for (document_terms) |terms| if (termFrequency(terms.items, term) > 0) {
                document_frequency += 1;
            };
            const frequency = termFrequency(document_terms[index].items, term);
            if (frequency == 0) continue;
            const n = @as(f64, @floatFromInt(chunks.len));
            const df = @as(f64, @floatFromInt(document_frequency));
            const idf = @log(1.0 + (n - df + 0.5) / (df + 0.5));
            const tf = @as(f64, @floatFromInt(frequency));
            const length = @as(f64, @floatFromInt(document_terms[index].items.len));
            const k1 = 1.2;
            const b = 0.75;
            score += idf * (tf * (k1 + 1.0)) / (tf + k1 * (1.0 - b + b * length / average_length));
        }
        results[index] = .{ .index = index, .score = score };
    }
    std.mem.sort(RankedChunk, results, {}, struct {
        fn less(_: void, a: RankedChunk, b: RankedChunk) bool {
            if (a.score == b.score) return a.index < b.index;
            return a.score > b.score;
        }
    }.less);
    return results;
}

pub fn answer(allocator: std.mem.Allocator, store: *const Store, document: []const u8, query: []const u8, context_budget: usize, client: *openai.Client, max_bytes: usize) ![]u8 {
    const index_path = if (std.mem.endsWith(u8, document, ".index.json")) try allocator.dupe(u8, document) else try std.fmt.allocPrint(allocator, "artifacts/extracted_text/{s}.index.json", .{document});
    defer allocator.free(index_path);
    const index_data = store.readAlloc(index_path, max_bytes) catch return error.DocumentNotFound;
    defer allocator.free(index_data);
    var parsed = try std.json.parseFromSlice(ingest.Index, allocator, index_data, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    var contents = try allocator.alloc([]const u8, parsed.value.chunks.len);
    defer allocator.free(contents);
    for (parsed.value.chunks, 0..) |chunk, index| contents[index] = try store.readAlloc(chunk.path, max_bytes);
    defer for (contents) |content| allocator.free(content);
    const ranking = try rank(allocator, query, contents);
    defer allocator.free(ranking);
    var evidence = std.ArrayList(u8).init(allocator);
    defer evidence.deinit();
    for (ranking) |item| {
        if (item.score <= 0 and evidence.items.len > 0) break;
        const chunk = parsed.value.chunks[item.index];
        const header = try std.fmt.allocPrint(allocator, "\nSOURCE {s} CHUNK {s} PAGE {any} SCORE {d:.6}\n", .{ chunk.source, chunk.id, chunk.page, item.score });
        defer allocator.free(header);
        if (evidence.items.len + header.len >= context_budget) break;
        try evidence.appendSlice(header);
        const remaining = context_budget - evidence.items.len;
        try evidence.appendSlice(contents[item.index][0..@min(remaining, contents[item.index].len)]);
        if (evidence.items.len >= context_budget) break;
    }
    const user = try std.fmt.allocPrint(allocator, "Query: {s}\n\nRanked evidence:\n{s}", .{ query, evidence.items });
    defer allocator.free(user);
    const messages = [_]protocol.Message{ .{ .role = "system", .content = prompts.document_answer_system }, .{ .role = "user", .content = user } };
    const response = try client.complete(.{ .messages = &messages, .response_schema_name = "document_answer" });
    defer response.deinit(allocator);
    const answer_id = try ids.generate(allocator, "answer");
    defer allocator.free(answer_id);
    const answer_path = try std.fmt.allocPrint(allocator, "artifacts/answers/{s}.md", .{answer_id});
    errdefer allocator.free(answer_path);
    const artifact = try std.fmt.allocPrint(allocator, "# Document Answer\n\n**Query:** {s}\n\n{s}\n\n## Ranked Evidence\n{s}\n", .{ query, response.content, evidence.items });
    defer allocator.free(artifact);
    try store.atomicWrite(answer_path, artifact);
    try manifest.update(allocator, store, answer_path, "document-answer", null, &.{ "answer", parsed.value.document_id }, max_bytes);
    return answer_path;
}

fn tokenize(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]u8) {
    var tokens = std.ArrayList([]u8).init(allocator);
    errdefer freeTokens(allocator, &tokens);
    var start: ?usize = null;
    for (text, 0..) |byte, index| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (start == null) start = index;
        } else if (start) |position| {
            if (index - position > 1) {
                const token = try std.ascii.allocLowerString(allocator, text[position..index]);
                try tokens.append(token);
            }
            start = null;
        }
    }
    if (start) |position| if (text.len - position > 1) try tokens.append(try std.ascii.allocLowerString(allocator, text[position..]));
    return tokens;
}

fn freeTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList([]u8)) void {
    for (tokens.items) |token| allocator.free(token);
    tokens.deinit();
}

fn termFrequency(tokens: []const []u8, term: []const u8) usize {
    var count: usize = 0;
    for (tokens) |token| if (std.mem.eql(u8, token, term)) {
        count += 1;
    };
    return count;
}
