const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;

pub fn makeFilePath(allocator: Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try mem.Allocator.dupe(allocator, u8, path);
    }
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
}

pub fn makeFilePathZ(allocator: Allocator, path: []const u8) ![:0]const u8 {
    const loc = try makeFilePath(allocator, path);
    defer allocator.free(loc);
    return try mem.Allocator.dupeZ(allocator, u8, path);
}

// Caller freed memory
pub fn getFileContents(allocator: Allocator, path: []const u8) ![]const u8 {
    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    const abs_path = try fs.cwd().realpath(path, &path_buf);
    const file = try fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
}

test "getFileContents(): relative and absolute path" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const abs_path = "/media/hdd/code/feed_app/test/sample-rss-2.xml";
    const abs_content = try getFileContents(allocator, abs_path);
    const rel_path = "test/sample-rss-2.xml";
    const rel_content = try getFileContents(allocator, rel_path);

    try expect(abs_content.len == rel_content.len);
}
