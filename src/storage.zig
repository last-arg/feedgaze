const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedInsert = feed_types.FeedInsert;
const FeedItem = feed_types.FeedItem;
const FeedItemInsert = feed_types.FeedItemInsert;
const sql = @import("sqlite");
const print = std.debug.print;

pub const Storage = struct {
    const Self = @This();
    allocator: Allocator,
    feeds: ArrayList(Feed),
    feed_id: usize = 0,
    feed_items: ArrayList(FeedItem),
    feed_item_id: usize = 0,

    sql_db: sql.Db,

    pub const Error = error{
        FeedNotFound,
        NotFound,
        FeedExists,
    };

    pub fn init(allocator: Allocator) !Self {
        var db = try sql.Db.init(.{
            .mode = .{ .Memory = {} },
            .open_flags = .{ .write = true, .create = true },
        });

        try setupDb(&db);

        return .{
            .allocator = allocator,
            .feeds = ArrayList(Feed).init(allocator),
            .feed_items = ArrayList(FeedItem).init(allocator),
            .sql_db = db,
        };
    }

    fn setupDb(db: *sql.Db) !void {
        const user_version = try db.pragma(usize, .{}, "user_version", null);
        if (user_version == null or user_version.? == 0) {
            errdefer std.log.err("Failed to create new database", .{});
            _ = try db.pragma(usize, .{}, "user_version", "1");
            _ = try db.pragma(usize, .{}, "foreign_keys", "1");
            _ = try db.pragma(usize, .{}, "journal_mode", "WAL");
            _ = try db.pragma(usize, .{}, "synchronous", "normal");
            _ = try db.pragma(usize, .{}, "temp_store", "2");
            _ = try db.pragma(usize, .{}, "cache_size", "-32000");
            std.log.info("New database created", .{});
        }

        try setupTables(db);
    }

    fn setupTables(db: *sql.Db) !void {
        errdefer std.log.err("Failed to create database tables", .{});
        inline for (tables) |query| {
            db.exec(query, .{}, .{}) catch |err| {
                std.log.debug("SQL_ERROR: {s}\n Failed query:\n{s}\n", .{ db.getDetailedError().message, query });
                return err;
            };
        }
        std.log.info("Created database tables", .{});
    }

    pub fn insertFeed(self: *Self, feed: Feed) !usize {
        const query =
            \\INSERT INTO feed (title, feed_url, page_url, updated_raw, updated_timestamp)
            \\VALUES (
            \\  @title,
            \\  @feed_url,
            \\  @page_url,
            \\  @updated_raw,
            \\  @updated_timestamp
            \\) ON CONFLICT(feed_url) DO NOTHING
            \\RETURNING feed_id;
        ;
        const feed_id = try one(&self.sql_db, usize, query, .{
            .title = feed.title,
            .feed_url = feed.feed_url,
            .page_url = feed.page_url,
            .updated_raw = feed.updated_raw,
            .updated_timestamp = feed.updated_timestamp,
        });
        return feed_id orelse Error.FeedExists;
    }

    pub fn getFeedsByUrl(self: *Self, allocator: Allocator, url: []const u8) ![]Feed {
        const query = "select feed_id, title, feed_url, page_url, updated_raw, updated_timestamp from feed where feed_url like '%' || ? || '%'";
        const feed = try selectAll(&self.sql_db, allocator, Feed, query, .{ .search = url });
        return feed;
    }

    fn hasUrl(url: []const u8, feeds: []Feed) bool {
        for (feeds) |feed| {
            if (std.mem.eql(u8, url, feed.feed_url)) {
                return true;
            }
        }
        return false;
    }

    pub fn getFeed(self: Self, id: usize) ?Feed {
        const index = findFeedIndex(id, self.feeds.items) orelse return null;
        return self.feeds.items[index];
    }

    fn findFeedIndex(id: usize, feeds: []Feed) ?usize {
        for (feeds) |f, i| {
            if (id == f.feed_id) {
                return i;
            }
        }
        return null;
    }

    pub fn deleteFeed(self: *Self, id: usize) !void {
        const index = findFeedIndex(id, self.feeds.items) orelse return Error.NotFound;
        _ = self.feeds.swapRemove(index);
        // TODO: delete items with feed_id
    }

    pub fn updateFeed(self: *Self, feed: Feed) !void {
        if (!try self.hasFeedWithId(feed.feed_id)) {
            return Error.FeedNotFound;
        }
        const query =
            \\UPDATE feed SET
            \\  title = @title,
            \\  feed_url = @feed_url,
            \\  page_url = @page_url,
            \\  updated_raw = @updated_raw,
            \\  updated_timestamp = @updated_timestamp
            \\WHERE feed_id = @feed_id;
        ;
        try self.sql_db.exec(query, .{}, feed);
    }

    pub fn deinit(self: *Self) void {
        self.feeds.deinit();
        self.feed_items.deinit();
    }

    pub fn hasFeedWithId(self: *Self, feed_id: usize) !bool {
        const exists_query = "SELECT EXISTS(SELECT 1 FROM feed WHERE feed_id = ?)";
        return (try one(&self.sql_db, bool, exists_query, .{feed_id})).?;
    }

    pub fn insertFeedItems(self: *Self, inserts: []FeedItem) ![]FeedItem {
        if (inserts.len == 0) {
            return error.NothingToInsert;
        }
        if (!try self.hasFeedWithId(inserts[0].feed_id)) {
            return Error.FeedNotFound;
        }

        const query =
            \\INSERT INTO item (feed_id, title, link, id, updated_raw, updated_timestamp)
            \\VALUES (@feed_id, @title, @link, @id, @updated_raw, @updated_timestamp)
            \\RETURNING item_id;
        ;

        for (inserts) |*item| {
            const item_id = try one(&self.sql_db, usize, query, .{
                .feed_id = item.feed_id,
                .title = item.title,
                .link = item.link,
                .id = item.id,
                .updated_raw = item.updated_raw,
                .updated_timestamp = item.updated_timestamp,
            });
            item.item_id = item_id;
        }
        return inserts;
    }

    pub fn getFeedItem(self: Self, id: usize) ?FeedItem {
        const index = findFeedItemIndex(id, self.feed_items.items) orelse return null;
        return self.feed_items.items[index];
    }

    fn findFeedItemIndex(id: usize, items: []FeedItem) ?usize {
        for (items) |item, i| {
            if (id == item.feed_id) {
                return i;
            }
        }
        return null;
    }

    pub fn deleteFeedItems(self: *Self, ids: []usize) !void {
        for (ids) |id| {
            const index = findFeedItemIndex(id, self.feed_items.items) orelse return Error.NotFound;
            _ = self.feed_items.swapRemove(index);
        }
    }

    pub fn updateFeedItem(self: *Self, id: usize, item_insert: FeedItemInsert) !void {
        assert(id > 0);
        const index = findFeedItemIndex(id, self.feed_items.items) orelse return Error.NotFound;
        self.feed_items.items[index] = item_insert.toFeedItem(id);
    }
};

const tables = &[_][]const u8{
    \\CREATE TABLE IF NOT EXISTS feed(
    \\  feed_id INTEGER PRIMARY KEY,
    \\  title TEXT NOT NULL,
    \\  feed_url TEXT NOT NULL UNIQUE,
    \\  page_url TEXT DEFAULT NULL,
    \\  updated_raw TEXT DEFAULT NULL,
    \\  updated_timestamp INTEGER DEFAULT NULL
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS item(
    \\  item_id INTEGER PRIMARY KEY,
    \\  feed_id INTEGER NOT NULL,
    \\  title TEXT NOT NULL,
    \\  link TEXT DEFAULT NULL,
    \\  id TEXT DEFAULT NULL,
    \\  updated_raw TEXT DEFAULT NULL,
    \\  updated_timestamp INTEGER DEFAULT NULL,
    \\  modified_at INTEGER DEFAULT (strftime('%s', 'now')),
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE,
    \\  UNIQUE(feed_id, id),
    \\  UNIQUE(feed_id, link)
    \\);
};

fn one(db: *sql.Db, comptime T: type, comptime query: []const u8, args: anytype) !?T {
    return db.one(T, query, .{}, args) catch |err| {
        std.log.debug("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn oneAlloc(db: *sql.Db, allocator: Allocator, comptime T: type, comptime query: []const u8, opts: anytype) !?T {
    return db.oneAlloc(T, allocator, query, .{}, opts) catch |err| {
        std.log.debug("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn selectAll(
    db: *sql.Db,
    allocator: Allocator,
    comptime T: type,
    comptime query: []const u8,
    opts: anytype,
) ![]T {
    var stmt = try db.prepare(query);
    defer stmt.deinit();
    const result = stmt.all(T, allocator, .{}, opts) catch |err| {
        std.log.debug("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
    return result;
}
