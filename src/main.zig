const std = @import("std");
const cli = @import("cli.zig");
const errors = @import("errors.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    cli.run(allocator, args) catch |err| {
        try std.io.getStdErr().writer().print("{{\"error\":\"{s}\",\"message\":{f}}}\n", .{ @errorName(err), std.json.fmt(errors.message(err), .{}) });
        std.process.exit(exitCode(err));
    };
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidArguments, error.InvalidConfiguration, error.InvalidPath, error.PathOutsideWorkspace => 2,
        error.WorkspaceLocked => 3,
        error.MissingApiKey, error.ProviderUnauthorized => 4,
        error.ProviderFailure, error.ProviderRateLimited, error.SearchProviderUnavailable => 5,
        error.AcceptanceFailed, error.InvalidLlmResponse, error.EvaluationFailed => 6,
        else => 1,
    };
}
