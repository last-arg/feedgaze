const std = @import("std");
const sql = @import("sqlite");
const Allocator = std.mem.Allocator;
const l = std.log;
const testing = std.testing;
const expect = testing.expect;
const shame = @import("shame.zig");

usingnamespace @import("queries.zig");

pub fn createDb(allocator: *Allocator, loc: ?[]const u8) !sql.Db {
    if (loc) |path| {
        const abs_loc = try shame.makeFilePathZ(allocator, path);
        defer allocator.free(abs_loc);
        return try createFileDb(abs_loc);
    } else {
        return try createMemoryDb();
    }
}

pub fn createMemoryDb() !sql.Db {
    var db: sql.Db = undefined;
    try db.init(.{
        .mode = sql.Db.Mode.Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
        // .threading_mode = .SingleThread,
    });
    return db;
}

pub fn createFileDb(path_opt: ?[:0]const u8) !sql.Db {
    var db: sql.Db = undefined;
    try db.init(.{
        .mode = if (path_opt) |path| sql.Db.Mode{ .File = path } else sql.Db.Mode.Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
        // .threading_mode = .MultiThread,
    });
    return db;
}

pub fn setup(db: *sql.Db) !void {
    // TODO?: use PRAGMA schema.user_version = integer ;
    _ = try db.pragma(usize, .{}, "foreign_keys", "1");

    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasDecl(decl.data.Type, "create")) {
            const sql_create = @field(decl.data.Type, "create");
            db.exec(sql_create, .{}) catch |err| {
                l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, sql_create });
                return err;
            };
        }
    }

    const version: usize = 1;
    try insert(db, Table.setting.insert, .{version});
}

pub fn verifyTables(db: *sql.Db) bool {
    const select_table = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;";
    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasField(decl.data.Type, "create")) {
            const row = one(usize, db, select_table, .{decl.name});
            if (row == null) return false;
            break;
        }
    }

    return true;
}

test "create and veriftyTables" {
    var db = try createMemory();
    try setup(&db);
    expect(verifyTables(&db));
}

// Non-alloc select query that returns one or no rows
pub fn one(comptime T: type, db: *sql.Db, comptime query: []const u8, args: anytype) !?T {
    return db.one(T, query, .{}, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn count(db: *sql.Db, comptime query: []const u8) !usize {
    const result = db.one(usize, query, .{}, .{}) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
    return result.?;
}

pub fn select(comptime T: type, allocator: *Allocator, db: *sql.Db, comptime query: []const u8, opts: anytype) !?T {
    return db.oneAlloc(T, allocator, query, .{}, opts) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn selectAll(
    comptime T: type,
    allocator: *Allocator,
    db: *sql.Db,
    comptime query: []const u8,
    opts: anytype,
) ![]T {
    var stmt = db.prepare(query) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
    defer stmt.deinit();
    return stmt.all(T, allocator, .{}, opts) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn insert(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    @setEvalBranchQuota(2000);

    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn update(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn delete(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

// Any memory freeing must be done by the caller
pub const Db = struct {
    const Self = @This();
    allocator: *Allocator,
    conn: *sql.Db,

    pub const FeedInsert = struct {
        title: []const u8,
        location: []const u8,
        link: ?[]const u8,
        updated_raw: ?[]const u8,
        updated_timestamp: ?i64,
    };

    pub const FeedUpdate = struct {
        title: []const u8,
        link: ?[]const u8,
        updated_raw: ?[]const u8,
        updated_timestamp: ?i64,
        id: usize,
    };

    pub const FeedSelect = struct {
        title: []const u8,
        location: []const u8,
        link: ?[]const u8,
        updated_raw: ?[]const u8,
        id: usize,
        updated_timestamp: ?i64,
    };

    pub fn insertFeed(db: *Self, data: FeedInsert) !void {
        try insert(db.conn, Table.feed.insert ++ Table.feed.on_conflict_location, .{
            data.title,
            data.location,
            data.link,
            data.updated_raw,
            data.updated_timestamp,
        });
    }

    pub fn selectFeedWhereLocation(db: *Self, location: []const u8) !?FeedSelect {
        return try select(
            FeedSelect,
            db.allocator,
            db.conn,
            Table.feed.select ++ Table.feed.where_location,
            .{location},
        );
    }

    pub fn selectFeedWhereId(db: *Self, id: usize) !?FeedSelect {
        return try select(
            FeedSelect,
            db.allocator,
            db.conn,
            Table.feed.select ++ Table.feed.where_id,
            .{id},
        );
    }

    pub fn deleteFeedWhereLocation(db: *Self, location: []const u8) !void {
        try delete(db.conn, Table.feed.delete_where_location, .{location});
    }

    pub fn deleteFeedWhereId(db: *Self, id: usize) !void {
        try delete(db.conn, Table.feed.delete_where_id, .{id});
    }

    pub fn updateFeedWhereId(db: *Self, data: FeedUpdate) !void {
        try update(db.conn, Table.feed.update_where_id, .{
            data.title,
            data.link,
            data.updated_raw,
            data.updated_timestamp,
            data.id,
        });
    }
};

const test_feed_insert_1 = Db.FeedInsert{
    .title = "Feed Example",
    .location = "https://example.com/feed.xml",
    .link = "https://example.com",
    .updated_raw = "valid_date",
    .updated_timestamp = 22,
};

const test_feed_insert_2 = Db.FeedInsert{
    .title = "Feed Other",
    .location = "https://other.com/feed.xml",
    .link = "https://other.com",
    .updated_raw = "valid_date",
    .updated_timestamp = 22,
};

var test_feed_update_1 = Db.FeedUpdate{
    .title = "Updated title",
    .link = test_feed_insert_1.link,
    .updated_raw = test_feed_insert_1.updated_raw,
    .updated_timestamp = test_feed_insert_1.updated_timestamp,
    .id = 1, // Overwrite if needed
};

// TODO: add and test update queries/fns
test "feed: insert, select, delete" {
    var data = test_feed_insert_1;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var db_conn = try createMemory();
    try setup(&db_conn);
    var db = Db{ .conn = &db_conn, .allocator = allocator };

    var row_count = try count(db.conn, "select count(*) from feed");
    expect(0 == row_count);

    try db.insertFeed(test_feed_insert_1);
    try db.insertFeed(test_feed_insert_1);
    row_count = try count(db.conn, "select count(*) from feed");
    expect(1 == row_count);

    try db.insertFeed(test_feed_insert_2);
    row_count = try count(db.conn, "select count(*) from feed");
    expect(2 == row_count);

    var feed_1 = try db.selectFeedWhereLocation(test_feed_insert_1.location);
    expect(1 == feed_1.?.id);
    testing.expectEqualStrings(test_feed_insert_1.title, feed_1.?.title);
    testing.expectEqualStrings(test_feed_insert_1.location, feed_1.?.location);
    testing.expectEqualStrings(test_feed_insert_1.link.?, feed_1.?.link.?);
    testing.expectEqualStrings(test_feed_insert_1.updated_raw.?, feed_1.?.updated_raw.?);
    expect(test_feed_insert_1.updated_timestamp.? == feed_1.?.updated_timestamp.?);

    test_feed_update_1.id = feed_1.?.id;
    try db.updateFeedWhereId(test_feed_update_1);
    feed_1 = try db.selectFeedWhereId(feed_1.?.id);
    testing.expectEqualStrings(test_feed_update_1.title, feed_1.?.title);

    try db.deleteFeedWhereLocation(test_feed_insert_1.location);
    row_count = try count(db.conn, "select count(*) from feed");
    expect(1 == row_count);

    const feed_2 = try db.selectFeedWhereId(2);
    testing.expectEqualStrings(test_feed_insert_2.location, feed_2.?.location);
    try db.deleteFeedWhereId(feed_2.?.id);
    row_count = try count(db.conn, "select count(*) from feed");
    expect(0 == row_count);
}
