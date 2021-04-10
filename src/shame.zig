const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub fn makeFilePath(allocator: *Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try mem.dupe(allocator, u8, path);
    }
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
}

pub fn makeFilePathZ(allocator: *Allocator, path: []const u8) ![:0]const u8 {
    const loc = try makeFilePath(allocator, path);
    defer allocator.free(loc);
    return try mem.Allocator.dupeZ(allocator, u8, path);
}
