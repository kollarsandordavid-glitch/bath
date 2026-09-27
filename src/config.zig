const std = @import("std");

pub const BackoffPolicy = enum { exponential, linear };

pub const Llm = struct {
    base_url: []const u8 = "http://127.0.0.1:8000/v1",
    api_key_env: []const u8 = "OPENAI_API_KEY",
    model: []const u8 = "gpt-oss-20b",
    temperature: f64 = 0.2,
    max_output_tokens: u32 = 2048,
    request_timeout_ms: u64 = 120000,
    retry_count: u8 = 3,
    backoff_policy: BackoffPolicy = .exponential,
    initial_backoff_ms: u64 = 500,
};

pub const Context = struct {
    recent_action_window: usize = 10,
    max_main_context_bytes: usize = 65536,
    max_artifact_snippet_bytes: usize = 4096,
    max_workspace_index_entries: usize = 200,
    document_answer_context_bytes: usize = 32768,
};

pub const Scheduler = struct {
    max_total_steps: u32 = 500,
    max_recursion_depth: u16 = 8,
    max_retries_per_task: u8 = 3,
    consolidation_interval: u16 = 10,
};

pub const CodeSandbox = struct {
    enabled: bool = false,
    subdirectory: []const u8 = "artifacts/code",
    timeout_ms: u64 = 30000,
    max_output_bytes: usize = 1048576,
    allowed_executables: []const []const u8 = &.{ "zig", "python3", "node", "sh" },
};

pub const Tools = struct {
    enabled: []const []const u8 = &.{ "file-read", "file-write", "file-list", "file-search", "http-fetch", "document-ingest", "document-answer" },
    allowed_web_search_providers: []const []const u8 = &.{"searxng"},
    searxng_base_url: ?[]const u8 = null,
    commercial_search_base_url: ?[]const u8 = null,
    commercial_search_api_key_env: []const u8 = "SEARCH_API_KEY",
    pdf_extraction_command: []const u8 = "pdftotext",
    http_timeout_ms: u64 = 60000,
    max_fetched_document_bytes: usize = 16777216,
    max_redirects: u8 = 5,
    code_execution: CodeSandbox = .{},
};

pub const Evaluation = struct {
    benchmark_task_files: []const []const u8 = &.{},
    output_report_directory: []const u8 = "evaluation",
    official_evaluator_command: ?[]const u8 = null,
    repeated_run_count: u16 = 1,
};

pub const Config = struct {
    workspace_root: []const u8 = ".",
    llm: Llm = .{},
    context: Context = .{},
    scheduler: Scheduler = .{},
    tools: Tools = .{},
    evaluation: Evaluation = .{},
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(Config, allocator, data, .{ .ignore_unknown_fields = false });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn validate(config: Config) !void {
    if (config.workspace_root.len == 0) return error.InvalidConfiguration;
    if (!std.mem.startsWith(u8, config.llm.base_url, "http://") and !std.mem.startsWith(u8, config.llm.base_url, "https://")) return error.InvalidConfiguration;
    if (config.llm.api_key_env.len == 0 or config.llm.model.len == 0) return error.InvalidConfiguration;
    if (!std.math.isFinite(config.llm.temperature) or config.llm.temperature < 0 or config.llm.temperature > 2) return error.InvalidConfiguration;
    if (config.llm.max_output_tokens == 0 or config.llm.request_timeout_ms == 0) return error.InvalidConfiguration;
    if (config.context.recent_action_window == 0 or config.context.max_main_context_bytes < 2048) return error.InvalidConfiguration;
    if (config.context.max_artifact_snippet_bytes == 0 or config.context.max_workspace_index_entries == 0) return error.InvalidConfiguration;
    if (config.scheduler.max_total_steps == 0 or config.scheduler.max_recursion_depth == 0 or config.scheduler.consolidation_interval == 0) return error.InvalidConfiguration;
    if (config.tools.max_fetched_document_bytes == 0 or config.tools.http_timeout_ms == 0 or config.tools.max_redirects > 20) return error.InvalidConfiguration;
    if (config.tools.code_execution.enabled and config.tools.code_execution.allowed_executables.len == 0) return error.InvalidConfiguration;
    if (config.evaluation.repeated_run_count == 0) return error.InvalidConfiguration;
}

pub fn isToolEnabled(config: Config, name: []const u8) bool {
    for (config.tools.enabled) |enabled| if (std.mem.eql(u8, enabled, name)) return true;
    return false;
}
