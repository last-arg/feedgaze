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
const ShowOptions = feed_types.ShowOptions;
const UpdateOptions = feed_types.UpdateOptions;
const parse = @import("./app_parse.zig");

pub const Storage = struct {
    const Self = @This();
    sql_db: sql.Db,
    options: Options = .{},

    const Options = struct {
        max_item_count: usize = 10,
    };

    var storage_arr = std.BoundedArray(u8, 4096).init(0) catch unreachable;

    pub const Error = error{
        FeedNotFound,
        FeedItemNotFound,
        NotFound,
        FeedExists,
    };

    pub fn init(path: ?[:0]const u8) !Self {
        const mode = if (path) |p| sql.Db.Mode{ .File = p } else sql.Db.Mode{ .Memory = {} };
        var db = try sql.Db.init(.{
            .mode = mode,
            .open_flags = .{ .write = true, .create = true },
        });

        try setupDb(&db);

        return .{
            .sql_db = db,
        };
    }

    fn setupDb(db: *sql.Db) !void {
        errdefer std.log.err("Failed to create new database", .{});
        const user_version = try db.pragma(usize, .{}, "user_version", null);
        if (user_version == null or user_version.? == 0) {
            _ = try db.pragma(usize, .{}, "user_version", "1");
            _ = try db.pragma(usize, .{}, "foreign_keys", "1");
            // TODO: For some tests disable 'journal_mode=delete'?
            _ = try db.pragma(usize, .{}, "journal_mode", "WAL");
            _ = try db.pragma(usize, .{}, "synchronous", "normal");
            _ = try db.pragma(usize, .{}, "temp_store", "2");
            _ = try db.pragma(usize, .{}, "mmap_size", "30000000000");
            _ = try db.pragma(usize, .{}, "cache_size", "-32000");
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
    }

    pub fn addFeed(self: *Self, arena: *std.heap.ArenaAllocator, content: []const u8, content_type: ?feed_types.ContentType, fallback_url: []const u8, headers: std.http.Headers) !void {
        var parsed = try parse.parse(arena.allocator(), content, content_type);
        if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
            parsed.feed.updated_raw = parsed.items[0].updated_raw;
        }
        try parsed.feed.prepareAndValidate(fallback_url);
        const feed_id = try self.insertFeed(parsed.feed);
        try FeedItem.prepareAndValidateAll(parsed.items, feed_id);
        _ = try self.insertFeedItems(parsed.items);
        try self.updateFeedUpdate(feed_id, FeedUpdate.fromHeaders(headers));
    }

    pub fn updateFeedAndItems(self: *Self, arena: *std.heap.ArenaAllocator, content: []const u8, content_type: ?feed_types.ContentType, feed_info: FeedToUpdate, headers: std.http.Headers) !void {
        var parsed = try parse.parse(arena.allocator(), content, content_type);
        if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
            parsed.feed.updated_raw = parsed.items[0].updated_raw;
        }

        parsed.feed.feed_id = feed_info.feed_id;
        try parsed.feed.prepareAndValidate(feed_info.feed_url);
        try self.updateFeed(parsed.feed);

        // Update feed items
        try FeedItem.prepareAndValidateAll(parsed.items, feed_info.feed_id);
        try self.updateAndRemoveFeedItems(parsed.items);

        // Update feed_update
        try self.updateFeedUpdate(feed_info.feed_id, FeedUpdate.fromHeaders(headers));
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
            \\FROM feed WHERE feed_url LIKE '%' || ? || '%' OR page_url LIKE '%' || ? || '%';
        ;
        return try selectAll(&self.sql_db, allocator, Feed, query, .{ url, url });
    }

    pub fn getLatestFeedsWithUrl(self: *Self, allocator: Allocator, inputs: [][]const u8, opts: ShowOptions) ![]Feed {
        const query_start =
            \\SELECT feed_id, title, feed_url, page_url, updated_raw, updated_timestamp 
            \\FROM feed 
        ;

        const query_like = "feed_url LIKE '%' || ? || '%' OR page_url LIKE '%' || ? || '%'";
        const query_order = "ORDER BY updated_timestamp DESC LIMIT {d};";

        try storage_arr.resize(0);
        try storage_arr.appendSlice(query_start);
        var values = try ArrayList([]const u8).initCapacity(allocator, inputs.len * 2);
        defer values.deinit();
        if (inputs.len > 0) {
            try storage_arr.append(' ');
            try storage_arr.appendSlice("WHERE");
            for (inputs, 0..) |term, i| {
                if (i != 0) {
                    try storage_arr.append(' ');
                    try storage_arr.appendSlice("AND");
                }
                try storage_arr.append(' ');
                try storage_arr.appendSlice(query_like);
                values.appendAssumeCapacity(term);
                values.appendAssumeCapacity(term);
            }
        }

        try storage_arr.append(' ');
        try storage_arr.writer().print(query_order, .{opts.limit});

        var stmt = try self.sql_db.prepareDynamic(storage_arr.slice());
        defer stmt.deinit();
        return try stmt.all(Feed, allocator, .{}, values.items);
    }

    fn hasUrl(url: []const u8, feeds: []Feed) bool {
        for (feeds) |feed| {
            if (std.mem.eql(u8, url, feed.feed_url)) {
                return true;
            }
        }
        return false;
    }

    pub fn hasFeedWithFeedUrl(self: *Self, url: []const u8) !bool {
        const query = "SELECT 1 from feed where feed_url = ?";
        return (try one(&self.sql_db, bool, query, .{url})) orelse false;
    }

    pub fn getFeedsToUpdate(self: *Self, allocator: Allocator, search_term: ?[]const u8, options: UpdateOptions) ![]FeedToUpdate {
        const query =
            \\SELECT 
            \\  feed.feed_id,
            \\  feed.feed_url,
            \\  feed_update.expires_utc,
            \\  feed_update.last_modified_utc,
            \\  feed_update.etag 
            \\FROM feed 
            \\LEFT JOIN feed_update ON feed.feed_id = feed_update.feed_id
            \\
        ;

        var prefix: []const u8 = "WHERE";
        storage_arr.resize(0) catch unreachable;
        storage_arr.appendSliceAssumeCapacity(query);

        if (options.force) {
            storage_arr.appendAssumeCapacity(' ');
            storage_arr.appendSliceAssumeCapacity(prefix);
            storage_arr.appendAssumeCapacity(' ');
            storage_arr.appendSliceAssumeCapacity("update_countdown < 0");
            prefix = "AND";
        }

        if (search_term) |term| {
            storage_arr.appendAssumeCapacity(' ');
            storage_arr.appendSliceAssumeCapacity(prefix);
            storage_arr.appendAssumeCapacity(' ');
            storage_arr.appendSliceAssumeCapacity("feed.feed_url LIKE '%' || ? || '%' or feed.page_url LIKE '%' || ? || '%';");
            var stmt = try self.sql_db.prepareDynamic(storage_arr.slice());
            defer stmt.deinit();
            return try stmt.all(FeedToUpdate, allocator, .{}, .{ term, term });
        }

        var stmt = try self.sql_db.prepareDynamic(storage_arr.slice());
        defer stmt.deinit();
        return try stmt.all(FeedToUpdate, allocator, .{}, .{});
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
            \\INSERT INTO item (feed_id, title, link, id, updated_raw, updated_timestamp, position)
            \\VALUES (@feed_id, @title, @link, @id, @updated_raw, @updated_timestamp, @position)
            \\RETURNING item_id;
        ;

        for (inserts, 0..) |*item, i| {
            const item_id = try one(&self.sql_db, usize, query, .{
                .feed_id = item.feed_id,
                .title = item.title,
                .link = item.link,
                .id = item.id,
                .updated_raw = item.updated_raw,
                .updated_timestamp = item.updated_timestamp,
                .position = i,
            });
            item.item_id = item_id;
        }
        return inserts;
    }

    pub fn getFeedItemsWithFeedId(self: *Self, allocator: Allocator, feed_id: usize) ![]FeedItem {
        const query = "select feed_id, item_id, title, id, link, updated_raw, updated_timestamp from item where feed_id = ?";
        return try selectAll(&self.sql_db, allocator, FeedItem, query, .{feed_id});
    }

    pub fn getLatestFeedItemsWithFeedId(self: *Self, allocator: Allocator, feed_id: usize, opts: ShowOptions) ![]FeedItem {
        const query =
            \\SELECT feed_id, item_id, title, id, link, updated_raw, updated_timestamp
            \\FROM item 
            \\WHERE feed_id = ?
            \\ORDER BY position ASC LIMIT ?;
        ;
        return try selectAll(&self.sql_db, allocator, FeedItem, query, .{ feed_id, opts.@"item-limit" });
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

    pub fn updateCountdowns(self: *Self) !void {
        // Update every update_countdown value
        // (expires_utc / 1000) - convert into seconds
        const query =
            \\WITH const AS (SELECT strftime('%s', 'now') as current_utc)
            \\UPDATE feed_update SET update_countdown = COALESCE(
            \\  (last_update + cache_control_max_age) - const.current_utc,
            \\  (expires_utc / 1000) - const.current_utc,
            \\  (last_update + (update_interval * 60)) - const.current_utc
            \\) from const;
        ;
        try self.sql_db.exec(query, .{}, .{});
    }

    pub fn updateFeedUpdate(self: *Self, feed_id: usize, feed_update: FeedUpdate) !void {
        const query =
            \\UPDATE feed_update SET
            \\  cache_control_max_age = @cache_control_max_age,
            \\  expires_utc = @expires_utc,
            \\  last_modified_utc = @last_modified_utc,
            \\  etag = @etag,
            \\  last_update = (strftime('%s', 'now'))
            \\WHERE feed_id = @feed_id;
        ;
        try self.sql_db.exec(query, .{}, .{
            .feed_id = feed_id,
            .cache_control_max_age = feed_update.cache_control_max_age,
            .expires_utc = feed_update.expires_utc,
            .last_modified_utc = feed_update.last_modified_utc,
            .etag = feed_update.etag,
        });
    }

    pub fn updateAndRemoveFeedItems(self: *Self, items: []FeedItem) !void {
        if (items.len == 0) {
            return;
        }
        try self.upsertFeedItems(items);
        try self.cleanFeedItems(items[0].feed_id, items.len);
    }

    // Initial item table state
    // 1 | Title 1 | 2
    // 2 | Title 2 | 1
    // Update item table
    // ...
    // 3 | Title 3 | 4
    // 4 | Title 4 | 3
    pub fn upsertFeedItems(self: *Self, inserts: []FeedItem) !void {
        if (inserts.len == 0) {
            return error.NothingToInsert;
        }
        if (!try self.hasFeedWithId(inserts[0].feed_id)) {
            return Error.FeedNotFound;
        }

        // Consider when inserting new items:
        // - There might be problem when there are more items in db than
        // are being inserted.
        // - there might be duplicate position values in the same feed_id
        // Can't use conflict(feed_id, position) because the item_id doesn't
        // change.
        const query =
            \\INSERT INTO item (feed_id, title, link, id, updated_raw, updated_timestamp, position)
            \\VALUES (@feed_id, @title, @link, @id, @updated_raw, @updated_timestamp, @position)
            \\ON CONFLICT(feed_id, id) DO UPDATE SET
            \\  title = excluded.title,
            \\  link = excluded.link,
            \\  updated_raw = excluded.updated_raw,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position
            \\WHERE updated_timestamp != excluded.updated_timestamp OR position != excluded.position
            \\ON CONFLICT(feed_id, link) DO UPDATE SET
            \\  title = excluded.title,
            \\  id = excluded.id,
            \\  updated_raw = excluded.updated_raw,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position
            \\WHERE updated_timestamp != excluded.updated_timestamp OR position != excluded.position
            \\ON CONFLICT(feed_id, position) DO UPDATE SET
            \\  item_id = (select max(item_id) + 1 from item),
            \\  title = excluded.title,
            \\  id = excluded.id,
            \\  link = excluded.link,
            \\  updated_raw = excluded.updated_raw,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position
            \\WHERE (id != excluded.id OR link != excluded.link OR title != excluded.title) 
            \\AND updated_timestamp != excluded.updated_timestamp
            \\;
        ;

        for (inserts, 0..) |item, i| {
            try self.sql_db.exec(query, .{}, .{
                .feed_id = item.feed_id,
                .title = item.title,
                .link = item.link,
                .id = item.id,
                .updated_raw = item.updated_raw,
                .updated_timestamp = item.updated_timestamp,
                .position = i,
            });
        }
    }

    pub fn cleanFeedItems(self: *Self, feed_id: usize, items_len: usize) !void {
        // Want to delete items:
        // - items that have same position
        // - items that are over max count
        const del_query =
            \\DELETE FROM item WHERE feed_id = ? AND position >= ?;
        ;
        const max_pos = @min(items_len, self.options.max_item_count);
        try self.sql_db.exec(del_query, .{}, .{ feed_id, max_pos });
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
    \\  position INTEGER DEFAULT 0,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE,
    \\  UNIQUE(feed_id, id),
    \\  UNIQUE(feed_id, link),
    \\  UNIQUE(feed_id, position)
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

fn testAddFeed(storage: *Storage) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const content = @embedFile("rss2.xml");
    const content_type = feed_types.ContentType.rss;
    const url = "http://localhost:8282/rss2.xml";
    var headers = try std.http.Headers.initList(allocator, &.{});
    defer headers.deinit();

    try storage.addFeed(&arena, content, content_type, url, headers);

    {
        const count = try storage.sql_db.one(usize, "select count(*) from feed", .{}, .{});
        try std.testing.expectEqual(@as(usize, 1), count.?);
    }

    {
        const count = try storage.sql_db.one(usize, "select count(*) from item", .{}, .{});
        try std.testing.expectEqual(@as(usize, 3), count.?);
    }
}

test "Storage.addFeed" {
    std.testing.log_level = .debug;
    var storage = try Storage.init(null);
    try testAddFeed(&storage);
}

test "Storage.deleteFeed" {
    std.testing.log_level = .debug;
    var storage = try Storage.init(null);
    try testAddFeed(&storage);
    try storage.deleteFeed(1);

    {
        const count = try storage.sql_db.one(usize, "select count(*) from feed", .{}, .{});
        try std.testing.expectEqual(@as(usize, 0), count.?);
    }

    {
        const count = try storage.sql_db.one(usize, "select count(*) from item", .{}, .{});
        try std.testing.expectEqual(@as(usize, 0), count.?);
    }
}

test "Storage.updateFeedAndItems" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var storage = try Storage.init(null);
    try testAddFeed(&storage);

    const content = @embedFile("rss2.xml");
    const content_type = feed_types.ContentType.rss;
    const url = "http://localhost:8282/rss2.xml";
    var headers = try std.http.Headers.initList(allocator, &.{});
    defer headers.deinit();

    const query = "DELETE FROM item WHERE feed_id = 1;";
    try storage.sql_db.exec(query, .{}, .{});

    {
        const count = try storage.sql_db.one(usize, "select count(*) from item", .{}, .{});
        try std.testing.expectEqual(@as(usize, 0), count.?);
    }

    const feed_info = .{
        .feed_id = 1,
        .feed_url = url,
    };

    try storage.updateFeedAndItems(&arena, content, content_type, feed_info, headers);

    {
        const count = try storage.sql_db.one(usize, "select count(*) from feed", .{}, .{});
        try std.testing.expectEqual(@as(usize, 1), count.?);
    }

    {
        const count = try storage.sql_db.one(usize, "select count(*) from item", .{}, .{});
        try std.testing.expectEqual(@as(usize, 3), count.?);
    }
}
