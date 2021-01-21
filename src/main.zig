const std = @import("std");
const sql = @import("sqlite");
const datetime = @import("datetime");
const Datetime = datetime.Datetime;
const timezones = datetime.timezones;
const rss = @import("rss.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const process = std.process;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const l = std.log;
usingnamespace @import("queries.zig");

pub const log_level = std.log.Level.info;

// Sqlite
// Do upsert with update and insert:
// https://stackoverflow.com/questions/15277373/sqlite-upsert-update-or-insert/38463024#38463024
// TODO: find domain's rss feeds
// 		html link application+xml
// 		for popular platforms can guess url. wordpress: /feed/
// TODO?: PRAGMA schema.user_version = integer ;
// TODO: implement downloading a file
// TODO: see if there is good way to detect local file path or url

pub fn main() anyerror!void {
    std.log.info("Main run", .{});
    const base_allocator = std.heap.page_allocator;
    // const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    // TODO: database creation/connection
    var db = try memoryDb();
    try dbSetup(&db);

    var iter = process.args();
    _ = iter.skip();

    while (iter.next(allocator)) |arg_err| {
        const arg = try arg_err;
        if (mem.eql(u8, "add", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try cliAddFeed(&db, allocator, value);
            } else {
                l.err("Subcommand add missing feed location", .{});
            }
        } else {
            return error.UnknownArgument;
        }
    }
}

// Using arena allocator so all memory will be freed by arena allocator
pub fn cliAddFeed(db: *sql.Db, allocator: *Allocator, location_raw: []const u8) !void {
    var location = try makeFilePath(allocator, location_raw);
    var contents = try getLocalFileContents(allocator, location);
    var rss_feed = try rss.Feed.init(allocator, location, contents);
    const feed_id = try addFeed(db, rss_feed, location);

    try insert(db, Table.feed_update.insert ++ Table.feed_update.on_conflict_feed_id, .{
        feed_id,
        rss_feed.info.ttl,
        rss_feed.info.last_build_date,
        rss_feed.info.last_build_date_utc,
    });

    try addFeedItems(db, rss_feed.items, feed_id);
}

pub fn insert(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    @setEvalBranchQuota(2000);

    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn update(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(Table.item.update, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

// Non-alloc select query that returns one or none rows
pub fn one(comptime T: type, db: *sql.Db, comptime query: []const u8, args: anytype) !?T {
    return db.one(T, query, .{}, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

test "add feed" {
    var allocator = testing.allocator;
    var location_raw: []const u8 = "./test/sample-rss-2.xml";

    var db = try memoryDb();
    try dbSetup(&db);

    var db_item = Item{
        .allocator = allocator,
        .db = &db,
    };

    var db_feed_update = FeedUpdate{
        .allocator = allocator,
        .db = &db,
    };

    var location = try makeFilePath(allocator, location_raw);
    defer allocator.free(location);

    var contents = try getLocalFileContents(allocator, location);
    defer allocator.free(contents);

    var rss_feed = try rss.Feed.init(allocator, location, contents);
    defer rss_feed.deinit();

    var db_feed = Feed.init(allocator, &db);

    const feed_id = try addFeed(db_feed, rss_feed, location);

    try insert(&db, Table.feed_update.insert, .{
        feed_id,
        rss_feed.info.ttl,
        rss_feed.info.last_build_date,
        rss_feed.info.last_build_date_utc,
    });
    {
        const updates = try db_feed_update.selectAll();
        defer db_feed_update.allocator.free(updates);
        testing.expect(1 == updates.len);
        for (updates) |u| {
            testing.expect(feed_id == u.feed_id);
        }
    }

    try addFeedItems(&db, rss_feed.items, feed_id);

    {
        try addFeedItems(&db, rss_feed.items, feed_id);
        // var items = try db_item.selectAll();
        // defer {
        //     for (items) |it| {
        //         l.warn("{s}", .{it.title});
        //         db_item.allocator.free(it.title);
        //         db_item.allocator.free(it.link);
        //         db_item.allocator.free(it.pub_date);
        //         db_item.allocator.free(it.created_at);
        //     }
        //     db_item.allocator.free(items);
        // }
    }

    const items_count = try one(usize, &db, Table.item.count_all, .{});
    testing.expectEqual(rss_feed.items.len, items_count.?);
}

pub const FeedUpdate = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    const Raw = struct {
        feed_id: usize,
        update_interval: usize,
        ttl: ?usize,
        last_update: i64,
    };

    pub fn selectAll(feed_update: Self) ![]Raw {
        var stmt = try feed_update.db.prepare(Table.feed_update.selectAll);
        defer stmt.deinit();
        return stmt.all(Raw, feed_update.allocator, .{}, .{}) catch |err| {
            l.warn("FeedUpdate.selectAll() failed. ERR: {s}\n", .{
                feed_update.db.getDetailedError().message,
            });
            return err;
        };
    }
};

pub fn addFeedItems(db: *sql.Db, feed_items: []rss.Item, feed_id: usize) !void {
    for (feed_items) |it| {
        if (it.guid) |_| {
            try insert(
                db,
                Table.item.insert ++ Table.item.on_conflict_guid,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        } else if (it.link) |_| {
            try insert(
                db,
                Table.item.insert ++ Table.item.on_conflict_link,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        } else if (it.pub_date != null and
            try one(bool, db, Table.item.has_item, .{ feed_id, it.pub_date_utc }) != null)
        {
            // Updates row if it matches feed_id and pub_date_utc
            try update(db, Table.item.update, .{
                // set column values
                it.title, it.link,         it.guid,
                // where
                feed_id,  it.pub_date_utc,
            });
        } else {
            try insert(
                db,
                Table.item.insert,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        }
    }
}

const Item = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    const Raw = struct {
        title: []const u8,
        link: []const u8,
        pub_date: []const u8,
        created_at: []const u8,
        // TODO: add guid: ?[]const u8
        // TODO: add pub_date_utc: ?i64
        feed_id: usize,
        id: usize,
    };

    pub fn deinitRaw(link: Self, raw: ?Raw) void {
        if (raw) |r| {
            link.allocator.free(r.title);
            link.allocator.free(r.link);
            link.allocator.free(r.pub_date);
            link.allocator.free(r.created_at);
        }
    }

    pub fn selectAll(item: Self) ![]Raw {
        var all_items = ArrayList(Raw).init(item.allocator);
        errdefer all_items.deinit();
        var all = try item.db.prepare(Table.item.select_all);
        defer all.deinit();
        var iter = try all.iterator(Raw, .{});
        while (try iter.nextAlloc(item.allocator, .{})) |link_row| {
            try all_items.append(link_row);
        }
        return all_items.toOwnedSlice();
    }
};

// location has to be absolute
pub fn getLocalFileContents(allocator: *Allocator, abs_location: []const u8) ![]const u8 {
    const local_file = try std.fs.openFileAbsolute(abs_location, .{});
    defer local_file.close();
    var file_stat = try local_file.stat();

    return try local_file.reader().readAllAlloc(allocator, file_stat.size);
}

pub fn addFeed(db: *sql.Db, rss_feed: rss.Feed, location_raw: []const u8) !usize {
    errdefer l.err("Failed to add feed '{s}'", .{location_raw});

    try insert(db, Table.feed.insert ++ Table.feed.on_conflict_location, .{
        rss_feed.info.title,
        rss_feed.info.link,
        rss_feed.info.location,
        rss_feed.info.pub_date,
        rss_feed.info.pub_date_utc,
    });

    // Just inserted feed, it has to exist
    const id = (try one(
        usize,
        db,
        Table.feed.select_id ++ Table.feed.where_location,
        .{rss_feed.info.location},
    )).?;
    return id;
}

pub const Feed = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    pub const Raw = struct {
        title: []const u8,
        link: []const u8,
        location: []const u8,
        id: usize,
        pub_date_utc: ?i64,
    };

    pub fn deinitRaw(feed: Self, raw: ?Raw) void {
        if (raw) |r| {
            feed.allocator.free(r.title);
            feed.allocator.free(r.link);
            feed.allocator.free(r.location);
        }
    }

    pub fn init(allocator: *Allocator, db: *sql.Db) Self {
        return Self{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn select(feed: Self) !?Raw {
        const db = feed.db;
        const allocator = feed.allocator;
        return db.oneAlloc(Raw, allocator, Table.feed.select, .{}, .{}) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select,
                db.getDetailedError().message,
            });
            return err;
        };
    }

    pub fn selectLocation(feed: Self, location: []const u8) !?Raw {
        const db = feed.db;
        const allocator = feed.allocator;
        return db.oneAlloc(
            Raw,
            allocator,
            Table.feed.select ++ Table.feed.where_location,
            .{},
            .{location},
        ) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select ++ Table.feed.where_location,
                db.getDetailedError().message,
            });
            return err;
        };
    }
};

pub fn memoryDb() !sql.Db {
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

pub fn tmpDb() !sql.Db {
    var db: sql.Db = undefined;
    try db.init(.{
        .mode = sql.Db.Mode{ .File = "/media/hdd/code/feed_inbox/tmp/test.db" },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    return db;
}

fn dbSetup(db: *sql.Db) !void {
    _ = try db.pragma(usize, .{}, "foreign_keys", .{"1"});

    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasDecl(decl.data.Type, "create")) {
            const sql_create = @field(decl.data.Type, "create");
            try db.exec(sql_create, .{});
        }
    }

    const version: usize = 1;
    try insert(db, Table.setting.insert, .{version});
}

pub fn verifyDbTables(db: *sql.Db) bool {
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

pub fn makeFilePath(allocator: *Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try mem.dupe(allocator, u8, path);
    }
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
}

const Setting = struct {
    version: usize,

    pub fn select(allocator: *Allocator, db: *sql.Db) !?Setting {
        return db.oneAlloc(Setting, allocator, Table.setting.select, .{}, .{}) catch |err| {
            l.warn("Failed to get setting. ERR: {s}\n", .{db.getDetailedError().message});
            return err;
        };
    }
};

test "verifyDbTables" {
    var allocator = testing.allocator;
    var db = try memoryDb();

    try dbSetup(&db);
    const result = verifyDbTables(&db);
    assert(result);
    const setting = (try Setting.select(allocator, &db)).?;
    assert(1 == setting.version);
}
