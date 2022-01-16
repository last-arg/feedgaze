const std = @import("std");
const sql = @import("sqlite");
const Allocator = std.mem.Allocator;
const l = std.log;
const testing = std.testing;
const expect = testing.expect;
const shame = @import("shame.zig");
const Table = @import("queries.zig").Table;

pub const Db = struct {
    const Self = @This();
    sql_db: sql.Db,
    allocator: Allocator,

    pub fn exec(self: *Self, comptime query: []const u8, args: anytype) !void {
        // @setEvalBranchQuota(2000);
        self.sql_db.exec(query, .{}, args) catch |err| {
            l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
    }

    // Non-alloc select query that returns one or no rows
    pub fn one(self: *Self, comptime T: type, comptime query: []const u8, args: anytype) !?T {
        return self.sql_db.one(T, query, .{}, args) catch |err| {
            l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
    }

    pub fn selectAll(
        self: *Self,
        comptime T: type,
        comptime query: []const u8,
        opts: anytype,
    ) ![]T {
        var stmt = self.sql_db.prepare(query) catch |err| {
            l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
        defer stmt.deinit();
        return stmt.all(T, self.allocator, .{}, opts) catch |err| {
            l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
    }
};

pub fn createDb(allocator: Allocator, loc: ?[]const u8) !sql.Db {
    if (loc) |path| {
        const abs_loc = try shame.makeFilePathZ(allocator, path);
        defer allocator.free(abs_loc);
        return try createFileDb(abs_loc);
    } else {
        return try createMemoryDb();
    }
}

pub fn createMemoryDb() !sql.Db {
    return try sql.Db.init(.{
        .mode = sql.Db.Mode.Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
        // .threading_mode = .SingleThread,
    });
}

pub fn createFileDb(path_opt: ?[:0]const u8) !sql.Db {
    return try sql.Db.init(.{
        .mode = if (path_opt) |path| sql.Db.Mode{ .File = path } else sql.Db.Mode.Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
        // .threading_mode = .MultiThread,
    });
}

pub fn setup(db: *sql.Db) !void {
    _ = try db.pragma(usize, .{}, "user_version", "1");
    _ = try db.pragma(usize, .{}, "foreign_keys", "1");
    _ = try db.pragma(usize, .{}, "journal_mode", "WAL");
    _ = try db.pragma(usize, .{}, "synchronous", "normal");

    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasDecl(decl.data.Type, "create")) {
            const sql_create = @field(decl.data.Type, "create");
            db.exec(sql_create, .{}, .{}) catch |err| {
                l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, sql_create });
                return err;
            };
        }
    }

    const version: usize = 1;
    try insert(db, Table.setting.insert, .{version});
}

// TODO: redo or move to Db
pub fn verifyTables(db: *sql.Db) bool {
    _ = db;
    // const select_table = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;";
    // inline for (@typeInfo(Table).Struct.decls) |decl| {
    //     if (@hasField(decl.data.Type, "create")) {
    //         const row = one(usize, db, select_table, .{decl.name});
    //         if (row == null) return false;
    //         break;
    //     }
    // }

    return true;
}

test "create and veriftyTables" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var db = try createDb(allocator, null);
    try setup(&db);
    expect(verifyTables(&db));
}

pub fn count(db: *sql.Db, comptime query: []const u8) !usize {
    const result = db.one(usize, query, .{}, .{}) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
    return result.?;
}

pub fn oneAlloc(comptime T: type, allocator: Allocator, db: *sql.Db, comptime query: []const u8, opts: anytype) !?T {
    return db.oneAlloc(T, allocator, query, .{}, opts) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn insert(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    // @setEvalBranchQuota(2000);

    db.exec(query, .{}, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn update(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(query, .{}, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn delete(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(query, .{}, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}
