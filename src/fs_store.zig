const std = @import("std");
const ids = @import("ids.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    root: []u8,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Store {
        try std.fs.cwd().makePath(root_path);
        const absolute = try std.fs.cwd().realpathAlloc(allocator, root_path);
        return .{ .allocator = allocator, .root = absolute };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.root);
    }

    pub fn validateRelative(relative: []const u8) !void {
        if (relative.len == 0 or std.fs.path.isAbsolute(relative) or std.mem.indexOfScalar(u8, relative, 0) != null) return error.InvalidPath;
        var iterator = std.mem.splitScalar(u8, relative, std.fs.path.sep);
        while (iterator.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.PathOutsideWorkspace;
        }
        if (std.fs.path.sep != '/') {
            var slash_iterator = std.mem.splitScalar(u8, relative, '/');
            while (slash_iterator.next()) |component| if (std.mem.eql(u8, component, "..")) return error.PathOutsideWorkspace;
        }
    }

    pub fn absolutePath(self: *const Store, relative: []const u8) ![]u8 {
        try validateRelative(relative);
        return std.fs.path.join(self.allocator, &.{ self.root, relative });
    }

    pub fn makePath(self: *const Store, relative: []const u8) !void {
        try validateRelative(relative);
        var root_dir = try std.fs.openDirAbsolute(self.root, .{});
        defer root_dir.close();
        try root_dir.makePath(relative);
    }

    pub fn exists(self: *const Store, relative: []const u8) bool {
        validateRelative(relative) catch return false;
        var root_dir = std.fs.openDirAbsolute(self.root, .{}) catch return false;
        defer root_dir.close();
        root_dir.access(relative, .{}) catch return false;
        return true;
    }

    pub fn readAlloc(self: *const Store, relative: []const u8, max_bytes: usize) ![]u8 {
        try validateRelative(relative);
        var root_dir = try std.fs.openDirAbsolute(self.root, .{});
        defer root_dir.close();
        const file = try root_dir.openFile(relative, .{});
        defer file.close();
        const stat = try file.stat();
        if (stat.size > max_bytes) return error.FileTooLarge;
        return file.readToEndAlloc(self.allocator, max_bytes);
    }

    pub fn atomicWrite(self: *const Store, relative: []const u8, data: []const u8) !void {
        try validateRelative(relative);
        const parent = std.fs.path.dirname(relative) orelse "";
        if (parent.len > 0) try self.makePath(parent);
        const temporary_id = try ids.generate(self.allocator, "tmp");
        defer self.allocator.free(temporary_id);
        const temporary = if (parent.len == 0)
            try std.fmt.allocPrint(self.allocator, ".{s}", .{temporary_id})
        else
            try std.fmt.allocPrint(self.allocator, "{s}/.{s}", .{ parent, temporary_id });
        defer self.allocator.free(temporary);
        var root_dir = try std.fs.openDirAbsolute(self.root, .{});
        defer root_dir.close();
        var file = try root_dir.createFile(temporary, .{ .exclusive = true });
        var closed = false;
        errdefer if (!closed) file.close();
        errdefer root_dir.deleteFile(temporary) catch {};
        try file.writeAll(data);
        try file.sync();
        file.close();
        closed = true;
        root_dir.rename(temporary, relative) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try root_dir.deleteFile(relative);
                try root_dir.rename(temporary, relative);
            },
            else => return err,
        };
    }

    pub fn appendLine(self: *const Store, relative: []const u8, data: []const u8) !void {
        try validateRelative(relative);
        const parent = std.fs.path.dirname(relative) orelse "";
        if (parent.len > 0) try self.makePath(parent);
        var root_dir = try std.fs.openDirAbsolute(self.root, .{});
        defer root_dir.close();
        const file = try root_dir.createFile(relative, .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(data);
        if (data.len == 0 or data[data.len - 1] != '\n') try file.writeAll("\n");
        try file.sync();
    }

    pub fn hashBytes(data: []const u8) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        return digest;
    }

    pub fn hashHexAlloc(self: *const Store, data: []const u8) ![]u8 {
        const digest = hashBytes(data);
        const encoded = std.fmt.bytesToHex(digest, .lower);
        return self.allocator.dupe(u8, &encoded);
    }

    pub fn hashFileHexAlloc(self: *const Store, relative: []const u8, max_bytes: usize) ![]u8 {
        const data = try self.readAlloc(relative, max_bytes);
        defer self.allocator.free(data);
        return self.hashHexAlloc(data);
    }
};
