const std = @import("std");

var sequence = std.atomic.Value(u64).init(0);

pub fn generate(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const counter = sequence.fetchAdd(1, .monotonic);
    var entropy: [24]u8 = undefined;
    std.crypto.random.bytes(entropy[0..16]);
    std.mem.writeInt(i64, entropy[16..24], std.time.milliTimestamp(), .little);
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&entropy);
    var counter_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_bytes, counter, .little);
    hasher.update(&counter_bytes);
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest[0..12], .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, encoded });
}
