const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const FeedUpdate = feed_types.FeedUpdate;
const FeedToUpdate = feed_types.FeedToUpdate;
const sql = @import("sqlite");
const print = std.debug.print;
const comptimePrint = std.fmt.comptimePrint;

pub const Storage = struct {
    const Self = @This();
    sql_db: sql.Db,

    pub const Error = error{
        FeedNotFound,
        FeedItemNotFound,
        NotFound,
        FeedExists,
    };

    pub fn init() !Self {
        var db = try sql.Db.init(.{
            .mode = .{ .Memory = {} },
            .open_flags = .{ .write = true, .create = true },
        });

        try setupDb(&db);

        return .{
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

    pub fn getFeedsWithUrl(self: *Self, allocator: Allocator, url: []const u8) ![]Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, updated_raw, updated_timestamp 
            \\FROM feed WHERE feed_url LIKE '%' || 'localhost' || '%' OR page_url LIKE '%' || ? || '%';
        ;
        return try selectAll(&self.sql_db, allocator, Feed, query, .{url});
    }

    pub fn getLatestFeedsWithUrl(self: *Self, allocator: Allocator, url: []const u8) ![]Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, updated_raw, updated_timestamp 
            \\FROM feed WHERE feed_url LIKE '%' || 'localhost' || '%' OR page_url LIKE '%' || ? || '%'
            \\ORDER BY updated_timestamp DESC;
        ;
        return try selectAll(&self.sql_db, allocator, Feed, query, .{url});
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

    pub fn hasFeedWithFeedUrl(self: *Self, url: []const u8) !bool {
        const query = "SELECT 1 from feed where feed_url = ?";
        return (try one(&self.sql_db, bool, query, .{url})) orelse false;
    }

    pub fn getFeedsToUpdate(self: *Self, allocator: Allocator, search_term: ?[]const u8) ![]FeedToUpdate {
        const query =
            \\SELECT 
            \\  feed.feed_id,
            \\  feed.feed_url,
            \\  feed_update.expires_utc,
            \\  feed_update.last_modified_utc,
            \\  feed_update.etag 
            \\FROM feed 
            \\LEFT JOIN feed_update ON feed.feed_id = feed_update.feed_id
        ;

        if (search_term) |term| {
            const query_term = query ++
                " WHERE feed.feed_url LIKE '%' || ? || '%' or feed.page_url LIKE '%' || ? || '%';";
            return try selectAll(&self.sql_db, allocator, FeedToUpdate, query_term, .{ term, term });
        }
        return try selectAll(&self.sql_db, allocator, FeedToUpdate, query, .{});
    }

    fn findFeedIndex(id: usize, feeds: []Feed) ?usize {
        for (feeds, 0..) |f, i| {
            if (id == f.feed_id) {
                return i;
            }
        }
        return null;
    }

    pub fn deleteFeed(self: *Self, id: usize) !void {
        try self.sql_db.exec("DELETE FROM feed WHERE feed_id = ?", .{}, .{id});
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

        var latest_count = try one(&self.sql_db, usize, "select max(latest_count) from item where feed_id = ?", .{inserts[0].feed_id}) orelse 0;
        latest_count += 1;

        const query =
            \\INSERT INTO item (feed_id, title, link, id, updated_raw, updated_timestamp, latest_count)
            \\VALUES (@feed_id, @title, @link, @id, @updated_raw, @updated_timestamp, @latest_count)
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
                .latest_count = latest_count,
            });
            item.item_id = item_id;
        }
        return inserts;
    }

    pub fn getFeedItemsWithFeedId(self: *Self, allocator: Allocator, feed_id: usize) ![]FeedItem {
        const query = "select feed_id, item_id, title, id, link, updated_raw, updated_timestamp from item where feed_id = ?";
        return try selectAll(&self.sql_db, allocator, FeedItem, query, .{feed_id});
    }

    pub fn getLatestFeedItemsWithFeedId(self: *Self, allocator: Allocator, feed_id: usize) ![]FeedItem {
        const query =
            \\SELECT feed_id, item_id, title, id, link, updated_raw, updated_timestamp
            \\FROM item 
            \\WHERE feed_id = ?
            \\ORDER BY updated_timestamp DESC, latest_count DESC, item_id ASC;
        ;
        return try selectAll(&self.sql_db, allocator, FeedItem, query, .{feed_id});
    }

    fn findFeedItemIndex(id: usize, items: []FeedItem) ?usize {
        for (items, 0..) |item, i| {
            if (id == item.feed_id) {
                return i;
            }
        }
        return null;
    }

    pub fn deleteFeedItemsWithFeedId(self: *Self, feed_id: usize) !void {
        const query = "DELETE FROM item WHERE feed_id = ?;";
        try self.sql_db.exec(query, .{}, .{feed_id});
    }

    pub fn updateFeedItem(self: *Self, item: FeedItem) !void {
        const query =
            \\update item set 
            \\  title = @title, 
            \\  feed_id = @feed_id, 
            \\  link = @link, 
            \\  id = @id, 
            \\  updated_raw = @updated_raw, 
            \\  updated_timestamp = @updated_timestamp
            \\where item_id = @item_id;
        ;
        try self.sql_db.exec(query, .{}, item);
    }

    pub fn insertFeedUpdate(self: *Self, feed_update: FeedUpdate) !void {
        if (feed_update.feed_id == null) {
            return error.FeedIdNull;
        }
        const query =
            \\INSERT INTO feed_update
            \\  (feed_id, cache_control_max_age, expires_utc, last_modified_utc, etag)
            \\VALUES (
            \\  @feed_id,
            \\  @cache_control_max_age,
            \\  @expires_utc,
            \\  @last_modified_utc,
            \\  @etag
            \\) ON CONFLICT(feed_id) DO UPDATE SET
            \\  cache_control_max_age = excluded.cache_control_max_age,
            \\  expires_utc = excluded.expires_utc,
            \\  last_modified_utc = excluded.last_modified_utc,
            \\  etag = excluded.etag,
            \\  last_update = (strftime('%s', 'now'));
        ;
        try self.sql_db.exec(query, .{}, feed_update);
    }

    pub fn updateFeedUpdate(self: *Self, feed_update: FeedUpdate) !void {
        if (feed_update.feed_id == null) {
            return error.FeedIdIsNull;
        }
        const query =
            \\UPDATE feed_update SET
            \\  cache_control_max_age = @cache_control_max_age,
            \\  expires_utc = @expires_utc,
            \\  last_modified_utc = @last_modified_utc,
            \\  etag = @etag,
            \\  last_update = (strftime('%s', 'now'))
            \\WHERE feed_id = @feed_id;
        ;
        try self.sql_db.exec(query, .{}, feed_update);
    }

    pub fn updateAndRemoveFeedItems(self: *Self, items: []FeedItem, clean_opts: CleanOptions) !void {
        try self.upsertFeedItems(items);
        try self.cleanFeedItems(items, clean_opts);
    }

    pub fn upsertFeedItems(self: *Self, inserts: []FeedItem) !void {
        if (inserts.len == 0) {
            return error.NothingToInsert;
        }
        if (!try self.hasFeedWithId(inserts[0].feed_id)) {
            return Error.FeedNotFound;
        }

        var latest_count = try one(&self.sql_db, usize, "select max(latest_count) from item where feed_id = ?", .{inserts[0].feed_id}) orelse 0;
        latest_count += 1;

        const query =
            \\INSERT INTO item (feed_id, title, link, id, updated_raw, updated_timestamp, latest_count)
            \\VALUES (@feed_id, @title, @link, @id, @updated_raw, @updated_timestamp, @latest_count)
            \\ON CONFLICT(feed_id, id) DO UPDATE SET
            \\  title = excluded.title,
            \\  link = excluded.link,
            \\  updated_raw = excluded.updated_raw,
            \\  updated_timestamp = excluded.updated_timestamp
            \\WHERE updated_timestamp != excluded.updated_timestamp
            \\ON CONFLICT(feed_id, link) DO UPDATE SET
            \\  title = excluded.title,
            \\  updated_raw = excluded.updated_raw,
            \\  updated_timestamp = excluded.updated_timestamp
            \\WHERE updated_timestamp != excluded.updated_timestamp;
        ;

        const query_no_id =
            \\INSERT INTO item (feed_id, title, updated_raw, updated_timestamp, latest_count)
            \\  select @feed_id, @title, @updated_raw, @updated_timestamp, @latest_count
            \\  where not exists (select * from item where feed_id == @w_feed_id and title == @w_title);
        ;

        for (inserts) |item| {
            if (item.link == null and item.id == null) {
                try self.sql_db.exec(query_no_id, .{}, .{
                    .feed_id = item.feed_id,
                    .title = item.title,
                    .updated_raw = item.updated_raw,
                    .updated_timestamp = item.updated_timestamp,
                    .latest_count = latest_count,
                    .w_feed_id = item.feed_id,
                    .w_title = item.title,
                });
            } else {
                try self.sql_db.exec(query, .{}, .{
                    .feed_id = item.feed_id,
                    .title = item.title,
                    .link = item.link,
                    .id = item.id,
                    .updated_raw = item.updated_raw,
                    .updated_timestamp = item.updated_timestamp,
                    .latest_count = latest_count,
                });
            }
        }
    }

    pub const CleanOptions = struct {
        max_item_count: usize = 10,
    };

    pub fn cleanFeedItems(self: *Self, items: ?[]FeedItem, opts: CleanOptions) !void {
        if (items == null) {
            // TODO: clean all items
            return;
        }
        const feed_items = items.?;
        const query =
            \\DELETE FROM item
            \\WHERE item_id IN
            \\  (SELECT item_id FROM item
            \\    WHERE feed_id = ?
            \\    ORDER BY id ASC
            \\    LIMIT (SELECT MAX(count(feed_id) - ?, 0) FROM item WHERE feed_id = ?)
            \\  );
        ;

        for (feed_items) |item| {
            try self.sql_db.exec(query, .{}, .{ item.feed_id, opts.max_item_count, item.feed_id });
        }
    }
};

pub const update_interval = 480; // in minutes
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
    // TODO: go back to added_at from latest_count.
    // With added added_at it would easier to get latest items
    \\  latest_count INTEGER DEFAULT 0,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE,
    \\  UNIQUE(feed_id, id),
    \\  UNIQUE(feed_id, link)
    \\);
    ,
    comptimePrint(
        \\CREATE TABLE IF NOT EXISTS feed_update (
        \\  feed_id INTEGER UNIQUE NOT NULL,
        \\  update_countdown INTEGER DEFAULT 0,
        \\  update_interval INTEGER DEFAULT {d},
        \\  last_update INTEGER DEFAULT (strftime('%s', 'now')),
        \\  cache_control_max_age INTEGER DEFAULT NULL,
        \\  expires_utc INTEGER DEFAULT NULL,
        \\  last_modified_utc INTEGER DEFAULT NULL,
        \\  etag TEXT DEFAULT NULL,
        \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
        \\);
    , .{ .update_interval = update_interval }),
};

pub fn one(db: *sql.Db, comptime T: type, comptime query: []const u8, args: anytype) !?T {
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
    var stmt = db.prepare(query) catch |err| {
        std.log.debug("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
    defer stmt.deinit();
    const result = stmt.all(T, allocator, .{}, opts) catch |err| {
        std.log.debug("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
    return result;
}
