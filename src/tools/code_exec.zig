const std = @import("std");
const Store = @import("../fs_store.zig").Store;
const config_module = @import("../config.zig");
const json_util = @import("../json_util.zig");
const ids = @import("../ids.zig");

pub const ExecutionResult = struct {
    exit_code: ?u8,
    signal: ?u32,
    stdout: []const u8,
    stderr: []const u8,
    produced_files: []const []const u8,
};

pub fn execute(allocator: std.mem.Allocator, store: *const Store, config: config_module.CodeSandbox, argv: []const []const u8) ![]u8 {
    if (!config.enabled) return error.ToolDisabled;
    if (argv.len == 0 or argv.len > 64) return error.ExecutionRejected;
    var executable_allowed = false;
    for (config.allowed_executables) |allowed| {
        if (std.mem.eql(u8, allowed, argv[0])) executable_allowed = true;
    }
    if (!executable_allowed) return error.ExecutionRejected;
    for (argv) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null or std.mem.indexOf(u8, argument, "../") != null or std.fs.path.isAbsolute(argument)) return error.ExecutionRejected;
        if (std.mem.indexOfAny(u8, argument, ";&|`$><")) |_| return error.ExecutionRejected;
    }
    try Store.validateRelative(config.subdirectory);
    try store.makePath(config.subdirectory);
    const cwd = try store.absolutePath(config.subdirectory);
    defer allocator.free(cwd);
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("HOME", cwd);
    try env.put("LANG", "C.UTF-8");
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = argv, .cwd = cwd, .env_map = &env, .max_output_bytes = config.max_output_bytes });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    var produced = std.ArrayList([]const u8).init(allocator);
    defer {
        for (produced.items) |item| allocator.free(item);
        produced.deinit();
    }
    var directory = try std.fs.openDirAbsolute(cwd, .{ .iterate = true });
    defer directory.close();
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| if (entry.kind == .file) try produced.append(try allocator.dupe(u8, entry.path));
    const exit_code: ?u8 = switch (result.term) {
        .Exited => |code| code,
        else => null,
    };
    const signal: ?u32 = switch (result.term) {
        .Signal => |number| number,
        else => null,
    };
    const record = ExecutionResult{ .exit_code = exit_code, .signal = signal, .stdout = result.stdout, .stderr = result.stderr, .produced_files = produced.items };
    const data = try json_util.stringifyAlloc(allocator, record);
    defer allocator.free(data);
    const execution_id = try ids.generate(allocator, "exec");
    defer allocator.free(execution_id);
    const path = try std.fmt.allocPrint(allocator, "logs/tool/{s}.json", .{execution_id});
    errdefer allocator.free(path);
    try store.atomicWrite(path, data);
    return path;
}
