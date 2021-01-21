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
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const logger = std.log;
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
// TODO: if feed.info.image_url == null get site's icon
// TODO: save image to database or file

pub fn main() anyerror!void {
    std.log.info("Main run", .{});
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

    var location = try makeFilePath(allocator, location_raw);
    defer allocator.free(location);

    var contents = try getLocalFileContents(allocator, location);
    defer allocator.free(contents);

    var rss_feed = try rss.Feed.init(allocator, location, contents);
    defer rss_feed.deinit();

    var db_feed = Feed.init(allocator, &db);

    const feed_id = try addFeed(db_feed, rss_feed, location);
    l.warn("feed_id: {}", .{feed_id});

    // try addFeedUpdate(db_feed, rss_feed, feed_id);
    try addFeedItems(db_item, rss_feed.items, feed_id);

    {
        try addFeedItems(db_item, rss_feed.items, feed_id);
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

    const items_count = try db_item.countAll();
    testing.expectEqual(rss_feed.items.len, items_count);
}

pub fn addFeedUpdate(db_item: Item, feed_items: []rss.Item, feed_id: usize) !void {
    //
}

pub fn addFeedItems(db_item: Item, feed_items: []rss.Item, feed_id: usize) !void {
    for (feed_items) |it| {
        if (it.guid) |_| {
            try db_item.insertQuery(
                Table.item.insert ++ Table.item.on_conflict_guid,
                it,
                feed_id,
            );
        } else if (it.link) |_| {
            try db_item.insertQuery(
                Table.item.insert ++ Table.item.on_conflict_link,
                it,
                feed_id,
            );
        } else if (it.pub_date != null and try db_item.hasItem(it, feed_id)) {
            // Updates row if it matches feed_id and pub_date_utc
            try db_item.update(it, feed_id);
        } else {
            try db_item.insertQuery(Table.item.insert, it, feed_id);
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
        // TODO: add guid
        feed_id: usize,
        id: usize,
    };

    pub fn hasItem(item: Self, rss_item: rss.Item, feed_id: usize) !bool {
        const result = item.db.one(
            usize,
            Table.item.has_item,
            .{},
            .{ feed_id, rss_item.pub_date_utc },
        ) catch |err| {
            l.err("Failed query '{}'. ERR: {}", .{ Table.item.count_all, err });
            return err;
        };
        return result != null;
    }

    pub fn update(
        item: Self,
        rss_item: rss.Item,
        feed_id: usize,
    ) !void {
        item.db.exec(Table.item.update, .{
            // set column values
            rss_item.title,
            rss_item.link,
            rss_item.guid,
            // where
            feed_id,
            rss_item.pub_date_utc,
        }) catch |err| {
            logger.warn("Item.update() failed. ERR: {s}\n", .{item.db.getDetailedError().message});
            return err;
        };
    }

    pub fn insertQuery(
        item: Self,
        comptime query: []const u8,
        rss_item: rss.Item,
        feed_id: usize,
    ) !void {
        @setEvalBranchQuota(10000);
        item.db.exec(query, .{
            feed_id,
            rss_item.title,
            rss_item.link,
            rss_item.guid,
            rss_item.pub_date,
            rss_item.pub_date_utc,
        }) catch |err| {
            logger.warn("Failed to insert new link. ERR: {s}\n", .{item.db.getDetailedError().message});
            return err;
        };
    }

    pub fn deinitRaw(link: Self, raw: ?Raw) void {
        if (raw) |r| {
            link.allocator.free(r.title);
            link.allocator.free(r.link);
            link.allocator.free(r.pub_date);
            link.allocator.free(r.created_at);
        }
    }

    pub fn countAll(item: Self) !usize {
        // There is always return value
        return (item.db.one(
            usize,
            Table.item.count_all,
            .{},
            .{},
        ) catch |err| {
            l.err("Failed query '{}'. ERR: {}", .{ Table.item.count_all, err });
            return err;
        }).?;
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
pub fn getLocalFileContents(allocator: *Allocator, location: []const u8) ![]const u8 {
    const local_file = try std.fs.openFileAbsolute(location, .{});
    defer local_file.close();
    var file_stat = try local_file.stat();

    return try local_file.reader().readAllAlloc(allocator, file_stat.size);
}

pub fn addFeed(feed: Feed, rss_feed: rss.Feed, location_raw: []const u8) !usize {
    errdefer logger.err("Failed to add feed '{s}'", .{location_raw});

    var over_write = false;
    const feed_result = try feed.selectLocation(rss_feed.info.location);
    defer feed.deinitRaw(feed_result);
    if (feed_result) |f| {
        try std.io.getStdOut().writeAll("Feed already exists\n");
        const changes_fmt =
            \\
            \\       | Current -> New
            \\ Title | {s} -> {s}
            \\ Link  | {s} -> {s}
            \\
            \\
        ;
        var changes_buf: [1024]u8 = undefined;
        const changes = try fmt.bufPrint(&changes_buf, changes_fmt, .{
            f.title, rss_feed.info.title,
            f.link,  rss_feed.info.link,
        });
        try std.io.getStdOut().writeAll(changes);
        try std.io.getStdOut().writeAll("Do you want to overwrite existing feed data (n/y)?\n");
        var read_buf: [32]u8 = undefined;
        var bytes = try std.io.getStdIn().read(&read_buf);
        over_write = 'y' == std.ascii.toLower(read_buf[0]);
        if (over_write) {
            try feed.updateId(rss_feed, f.id);
        }
    } else {
        try feed.insert(rss_feed);
    }
    const id = blk: {
        if (over_write) break :blk feed_result.?.id;

        const id_opt = try feed.oneLocationId(rss_feed.info.location);
        break :blk id_opt.?;
    };
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
        return db.oneAlloc(Raw, allocator, Query.select.feed, .{}, .{}) catch |err| {
            logger.warn("Failed query `{s}`. ERR: {s}\n", .{
                Query.select.feed,
                db.getDetailedError().message,
            });
            return err;
        };
    }

    pub fn oneLocationId(feed: Self, location: []const u8) !?usize {
        return try feed.db.one(
            usize,
            "SELECT id FROM feed WHERE location = ?",
            .{},
            .{location},
        );
    }

    pub fn selectLocation(feed: Self, location: []const u8) !?Raw {
        const db = feed.db;
        const allocator = feed.allocator;
        return db.oneAlloc(
            Raw,
            allocator,
            Query.select.feed_location,
            .{},
            .{location},
        ) catch |err| {
            logger.warn("Failed query `{s}`. ERR: {s}\n", .{
                Query.select.feed,
                db.getDetailedError().message,
            });
            return err;
        };
    }

    pub fn insert(feed: Self, feed_rss: rss.Feed) !void {
        const db = feed.db;
        db.exec(Query.insert.feed, .{
            feed_rss.info.title,
            feed_rss.info.link,
            feed_rss.info.location,
            feed_rss.info.pub_date,
            feed_rss.info.pub_date_utc,
        }) catch |err| {
            logger.warn("Failed to insert new feed. ERROR: {s}\n", .{db.getDetailedError().message});
            return err;
        };
    }

    pub fn updateId(feed: Self, feed_rss: rss.Feed, id: usize) !void {
        const db = feed.db;
        db.exec(Query.update.feed_id, .{
            feed_rss.info.title,
            feed_rss.info.link,
            feed_rss.info.pub_date,
            feed_rss.info.pub_date_utc,
            id,
        }) catch |err| {
            logger.warn("Failed to insert new feed. ERROR: {s}\n", .{db.getDetailedError().message});
            return err;
        };
    }

    // pub fn deinit(feed: Self) void {
    //     //
    // }
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

    try Setting.insert(db, 1);
}

pub fn verifyDbTables(db: *sql.Db) bool {
    const max_len = 128;
    const select_table = "SELECT name FROM sqlite_master WHERE type='table' AND name=? ;";
    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasField(decl.data.Type, "create")) {
            assert(decl.name.len < max_len);
            const row = db.one([max_len:0]u8, select_table, .{}, .{decl.name}) catch |err| {
                logger.warn("{s}\n", .{db.getDetailedError().message});
                return false;
            };
            if (row) |name| {
                if (!mem.eql(u8, decl.name, mem.spanZ(&name))) {
                    return false;
                }
            }
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
        return db.oneAlloc(Setting, allocator, Query.select.setting, .{}, .{}) catch |err| {
            logger.warn("Failed to get setting. ERR: {s}\n", .{db.getDetailedError().message});
            return err;
        };
    }
    pub fn insert(db: *sql.Db, version: usize) !void {
        db.exec(Query.insert.setting, .{version}) catch |err| {
            logger.warn("Failed to insert new link. ERROR: {s}\n", .{db.getDetailedError().message});
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
