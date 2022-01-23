const std = @import("std");
const sql = @import("sqlite");
const Allocator = std.mem.Allocator;
const log = std.log;
const testing = std.testing;
const print = std.debug.print;
const expect = testing.expect;
const shame = @import("shame.zig");
const Table = @import("queries.zig").Table;

pub const Db = struct {
    const Self = @This();
    sql_db: sql.Db,
    allocator: Allocator,

    // abs_path == null will create in memory database
    pub fn init(allocator: Allocator, abs_path: ?[:0]const u8) !Db {
        const mode: sql.Db.Mode = blk: {
            if (abs_path) |path| {
                std.debug.assert(std.fs.path.isAbsoluteZ(path));
                break :blk .{ .File = path };
            }
            break :blk .{ .Memory = .{} };
        };
        var sql_db = try sql.Db.init(.{
            .mode = mode,
            .open_flags = .{ .write = true, .create = true },
            // .threading_mode = .SingleThread,
        });
        var db = Db{ .sql_db = sql_db, .allocator = allocator };
        try setup(&db);
        return db;
    }

    pub fn exec(self: *Self, comptime query: []const u8, args: anytype) !void {
        self.sql_db.exec(query, .{}, args) catch |err| {
            log.err("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
    }

    // Non-alloc select query that returns one or no rows
    pub fn one(self: *Self, comptime T: type, comptime query: []const u8, args: anytype) !?T {
        return self.sql_db.one(T, query, .{}, args) catch |err| {
            log.err("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
    }

    pub fn oneAlloc(comptime T: type, allocator: Allocator, db: *sql.Db, comptime query: []const u8, opts: anytype) !?T {
        return db.oneAlloc(T, allocator, query, .{}, opts) catch |err| {
            log.err("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
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
            log.err("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
        defer stmt.deinit();
        return stmt.all(T, self.allocator, .{}, opts) catch |err| {
            log.err("SQL_ERROR: {s}\n Failed query:\n{s}", .{ self.sql_db.getDetailedError().message, query });
            return err;
        };
    }
};

pub fn setup(db: *Db) !void {
    const user_version = try db.sql_db.pragma(usize, .{}, "user_version", null);
    if (user_version == null or user_version.? == 0) {
        log.info("Creating new database", .{});
        _ = try db.sql_db.pragma(usize, .{}, "user_version", "1");
        _ = try db.sql_db.pragma(usize, .{}, "foreign_keys", "1");
        _ = try db.sql_db.pragma(usize, .{}, "journal_mode", "WAL");
        _ = try db.sql_db.pragma(usize, .{}, "synchronous", "normal");
        _ = try db.sql_db.pragma(usize, .{}, "temp_store", "2");
        _ = try db.sql_db.pragma(usize, .{}, "cache_size", "-32000");

        inline for (@typeInfo(Table).Struct.decls) |decl| {
            if (@hasDecl(decl.data.Type, "create")) {
                const sql_create = @field(decl.data.Type, "create");
                db.sql_db.exec(sql_create, .{}, .{}) catch |err| {
                    log.err("SQL_ERROR: {s}\n Failed query:\n{s}\n", .{ db.sql_db.getDetailedError().message, sql_create });
                    return err;
                };
            }
        }
    }
}

pub fn verifyTables(db: *sql.Db) bool {
    const select_table = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;";
    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasField(decl.data.Type, "create")) {
            const row = db.one(usize, db, select_table, .{decl.name});
            if (row == null) return false;
            break;
        }
    }
    return true;
}

test "create and veriftyTables" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var db = try Db.init(allocator, null);
    try expect(verifyTables(&db.sql_db));
}
