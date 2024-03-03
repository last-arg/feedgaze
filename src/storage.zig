const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const types = @import("./feed_types.zig");
const Feed = types.Feed;
const FeedItem = types.FeedItem;
const FeedItemRender = types.FeedItemRender;
const FeedUpdate = types.FeedUpdate;
const FeedToUpdate = types.FeedToUpdate;
const FeedOptions = types.FeedOptions;
const sql = @import("sqlite");
const print = std.debug.print;
const comptimePrint = std.fmt.comptimePrint;
const ShowOptions = types.ShowOptions;
const UpdateOptions = types.UpdateOptions;
const parse = @import("./app_parse.zig");
const app_config = @import("app_config.zig");

pub const Storage = struct {
    const Self = @This();
    sql_db: sql.Db,
    options: Options = .{},

    const Options = struct {
        max_item_count: usize = app_config.max_items,
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
        const user_version = try db.pragma(usize, .{}, "user_version", null) orelse 0;
        if (user_version == 0) {
            // NOTE: permanent pragmas:
            // - application_id
            // - journal_mode (when enabling or disabling WAL mode)
            // - schema_version
            // - user_version
            // - wal_checkpoint
            _ = try db.pragma(void, .{}, "user_version", "1");
        }
        _ = try db.pragma(void, .{}, "foreign_keys", "1");
        // TODO: For some tests disable 'journal_mode=delete'?
        _ = try db.pragma(void, .{}, "journal_mode", "WAL");
        _ = try db.pragma(void, .{}, "synchronous", "normal");
        _ = try db.pragma(void, .{}, "temp_store", "2");
        _ = try db.pragma(void, .{}, "mmap_size", "30000000000");
        _ = try db.pragma(void, .{}, "cache_size", "-32000");

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

    pub fn addFeed(self: *Self, arena: *std.heap.ArenaAllocator, feed_opts: FeedOptions, fallback_title: ?[]const u8) !void {
        var parsed = try parse.parse(arena.allocator(), feed_opts.body, feed_opts.content_type);
        if (parsed.feed.updated_timestamp == null and parsed.items.len > 0) {
            parsed.feed.updated_timestamp = parsed.items[0].updated_timestamp;
        }
        try parsed.feed.prepareAndValidate(arena);
        if (parsed.feed.title == null) {
            parsed.feed.title = fallback_title;
        }
        const feed_id = try self.insertFeed(parsed.feed);
        try FeedItem.prepareAndValidateAll(parsed.items, feed_id);
        _ = try self.insertFeedItems(parsed.items);
        try self.updateFeedUpdate(feed_id, feed_opts.feed_updates);
    }

    const curl = @import("curl");
    const ContentType = parse.ContentType;
    pub fn updateFeedAndItems(self: *Self, arena: *std.heap.ArenaAllocator, resp: curl.Easy.Response, feed_info: FeedToUpdate) !void {
        const content = resp.body.items;
        const content_type = blk: {
            const value = resp.get_header("content-type") catch null;
            if (value) |v| {
                break :blk ContentType.fromString(v.get());
            }
            break :blk null;
        };


        var parsed = try parse.parse(arena.allocator(), content, content_type);
        if (parsed.feed.updated_timestamp == null and parsed.items.len > 0) {
            parsed.feed.updated_timestamp = parsed.items[0].updated_timestamp;
        }

        parsed.feed.feed_id = feed_info.feed_id;
        try parsed.feed.prepareAndValidate(arena);
        try self.updateFeed(parsed.feed);

        // Update feed items
        try FeedItem.prepareAndValidateAll(parsed.items, feed_info.feed_id);
        try self.updateAndRemoveFeedItems(parsed.items);

        // Update feed_update
        try self.updateFeedUpdate(feed_info.feed_id, FeedUpdate.fromCurlHeaders(resp));
    }

    pub fn insertFeed(self: *Self, feed: Feed) !usize {
        const query =
            \\INSERT INTO feed (title, feed_url, page_url, updated_timestamp)
            \\VALUES (
            \\  @title,
            \\  @feed_url,
            \\  @page_url,
            \\  @updated_timestamp
            \\) ON CONFLICT(feed_url) DO NOTHING
            \\RETURNING feed_id;
        ;
        const feed_id = try one(&self.sql_db, usize, query, .{
            .title = feed.title,
            .feed_url = feed.feed_url,
            .page_url = feed.page_url,
            .updated_timestamp = feed.updated_timestamp,
        });
        return feed_id orelse Error.FeedExists;
    }

    pub fn getFeedsWithUrl(self: *Self, allocator: Allocator, url: []const u8) ![]Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, updated_timestamp 
            \\FROM feed WHERE feed_url LIKE '%' || ? || '%' OR page_url LIKE '%' || ? || '%';
        ;
        return try selectAll(&self.sql_db, allocator, Feed, query, .{ url, url });
    }

    pub fn getLatestFeedsWithUrl(self: *Self, allocator: Allocator, inputs: [][]const u8, opts: ShowOptions) ![]Feed {
        const query_start =
            \\SELECT feed_id, title, feed_url, page_url, updated_timestamp 
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
            \\  feed_update.last_modified_utc,
            \\  feed_update.etag 
            \\FROM feed 
            \\LEFT JOIN feed_update ON feed.feed_id = feed_update.feed_id
            \\
        ;

        var prefix: []const u8 = "WHERE";
        storage_arr.resize(0) catch unreachable;
        storage_arr.appendSliceAssumeCapacity(query);

        if (!options.force) {
            storage_arr.appendAssumeCapacity(' ');
            storage_arr.appendSliceAssumeCapacity(prefix);
            storage_arr.appendSliceAssumeCapacity(" (update_countdown < 0 OR update_countdown IS NULL)");
            prefix = "AND";
        }

        if (search_term) |term| {
            if (term.len > 0) {
                storage_arr.appendAssumeCapacity(' ');
                storage_arr.appendSliceAssumeCapacity(prefix);
                storage_arr.appendAssumeCapacity(' ');
                storage_arr.appendSliceAssumeCapacity("(feed.feed_url LIKE '%' || ? || '%' OR feed.page_url LIKE '%' || ? || '%');");
                var stmt = try self.sql_db.prepareDynamic(storage_arr.slice());
                defer stmt.deinit();
                return try stmt.all(FeedToUpdate, allocator, .{}, .{ term, term });
            }
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
            \\INSERT INTO item (feed_id, title, link, id, updated_timestamp, position)
            \\VALUES (@feed_id, @title, @link, @id, @updated_timestamp, @position)
            \\RETURNING item_id;
        ;

        const len = @min(inserts.len, app_config.max_items);
        for (inserts[0..len], 0..) |*item, i| {
            const item_id = try one(&self.sql_db, usize, query, .{
                .feed_id = item.feed_id,
                .title = item.title,
                .link = item.link,
                .id = item.id,
                .updated_timestamp = item.updated_timestamp,
                .position = i,
            });
            item.item_id = item_id;
        }
        return inserts;
    }

    pub fn getLatestFeedItemsWithFeedId(self: *Self, allocator: Allocator, feed_id: usize, opts: ShowOptions) ![]FeedItem {
        const query =
            \\SELECT feed_id, item_id, title, id, link, updated_timestamp
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

    // Update every update_countdown value
    pub fn updateCountdowns(self: *Self) !void {
        const query =
            \\UPDATE feed_update SET 
            \\  update_countdown = (last_update + update_interval) - strftime('%s', 'now')
        ;
        try self.sql_db.exec(query, .{}, .{});
    }

    pub fn updateFeedUpdate(self: *Self, feed_id: usize, feed_update: FeedUpdate) !void {
        const query =
            \\INSERT INTO feed_update 
            \\  (feed_id, update_interval, last_modified_utc, etag)
            \\VALUES 
            \\  (@feed_id, @update_interval, @last_modified_utc, @etag)
            \\ ON CONFLICT(feed_id) DO UPDATE SET
            \\  update_interval = @u_update_interval,
            \\  last_modified_utc = @u_last_modified_utc,
            \\  etag = @u_etag,
            \\  last_update = strftime('%s', 'now')
            \\;
        ;
        try self.sql_db.exec(query, .{}, .{
            .feed_id = feed_id,
            .update_interval = feed_update.update_interval,
            .last_modified_utc = feed_update.last_modified_utc,
            .etag = feed_update.etag,
            .u_update_interval = feed_update.update_interval,
            .u_last_modified_utc = feed_update.last_modified_utc,
            .u_etag = feed_update.etag,
        });
    }

    pub fn updateLastUpdate(self: *Self, feed_id: usize) !void {
        const query = "update feed_update set last_update = strftime('%s', 'now') where feed_id = @feed_id;";
        try self.sql_db.exec(query, .{}, .{.feed_id = feed_id});
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

        const query_with_id =
            \\INSERT INTO item (feed_id, title, link, id, updated_timestamp, position)
            \\VALUES (@feed_id, @title, @link, @id, @updated_timestamp, @position)
            \\ON CONFLICT(feed_id, id) DO UPDATE SET
            \\  title = excluded.title,
            \\  link = excluded.link,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position,
            \\  last_modified = strftime('%s', 'now')
            \\WHERE updated_timestamp IS NULL 
            \\  OR updated_timestamp != excluded.updated_timestamp 
            \\  OR position != excluded.position
            \\ON CONFLICT(feed_id, link) DO UPDATE SET
            \\  title = excluded.title,
            \\  id = excluded.id,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position,
            \\  last_modified = strftime('%s', 'now')
            \\WHERE updated_timestamp IS NULL 
            \\  OR updated_timestamp != excluded.updated_timestamp 
            \\  OR position != excluded.position
            \\;
        ;

        const query_without_id =
            \\update item set 
            \\  title = @u_title,
            \\  updated_timestamp = @u_timestamp,
            \\  last_modified = strftime('%s', 'now')
            \\where feed_id = @u_feed_id and position = @u_position;
            \\INSERT INTO item (feed_id, title, updated_timestamp, position)
            \\select @feed_id, @title, @updated_timestamp, @position where (select changes() = 0)
            \\;
        ;
        
        for (inserts, 0..) |item, i| {
            if (item.id != null or item.link != null) {
                try self.sql_db.exec(query_with_id, .{}, .{
                    .feed_id = item.feed_id,
                    .title = item.title,
                    .link = item.link,
                    .id = item.id,
                    .updated_timestamp = item.updated_timestamp,
                    .position = i,
                });
            } else {
                try self.sql_db.exec(query_without_id, .{}, .{
                    .u_title = item.title,
                    .u_timestamp = item.updated_timestamp,
                    .u_feed_id = item.feed_id,
                    .u_position = i,

                    .feed_id = item.feed_id,
                    .title = item.title,
                    .updated_timestamp = item.updated_timestamp,
                    .position = i,
                });
            }
        }
    }

    pub fn cleanFeedItems(self: *Self, feed_id: usize, items_len: usize) !void {
        const last_pos = items_len - 1;
        const del_query =
            \\DELETE FROM item WHERE feed_id = ? AND 
            \\  (position > ? OR
            \\   last_modified < (SELECT last_modified FROM item where feed_id = ? AND position = ? order by last_modified DESC limit 1));
        ;
        try self.sql_db.exec(del_query, .{}, .{ feed_id, last_pos, feed_id, last_pos });
    }

    pub fn getSmallestCountdown(self: *Self) !?i64 {
        const query = "SELECT update_countdown FROM feed_update ORDER BY update_countdown ASC LIMIT 1;";
        return try one(&self.sql_db, i64, query, .{});
    }

    pub fn feed_items_with_feed_id(self: *Self, alloc: Allocator, feed_id: usize) ![]FeedItemRender {
        const query_item =
            \\select title, link, updated_timestamp 
            \\from item where feed_id = ? order by updated_timestamp DESC, position ASC;
        ;
        return try selectAll(&self.sql_db, alloc, FeedItemRender, query_item, .{feed_id});
    }

    pub fn feeds_all(self: *Self, alloc: Allocator) ![]types.FeedRender {
        const query_feed =
            \\select * from feed order by updated_timestamp DESC;
        ;
        return try selectAll(&self.sql_db, alloc, types.FeedRender, query_feed, .{});
    }
};

const tables = &[_][]const u8{
    \\CREATE TABLE IF NOT EXISTS feed(
    \\  feed_id INTEGER PRIMARY KEY,
    \\  title TEXT NOT NULL,
    \\  feed_url TEXT NOT NULL UNIQUE,
    \\  page_url TEXT DEFAULT NULL,
    \\  updated_timestamp INTEGER DEFAULT NULL
    \\);
    ,
    \\CREATE TABLE IF NOT EXISTS item(
    \\  item_id INTEGER PRIMARY KEY,
    \\  feed_id INTEGER NOT NULL,
    \\  title TEXT NOT NULL,
    \\  link TEXT DEFAULT NULL,
    \\  id TEXT DEFAULT NULL,
    \\  updated_timestamp INTEGER DEFAULT NULL,
    \\  position INTEGER NOT NULL DEFAULT 0,
    \\  last_modified INTEGER DEFAULT (strftime("%s", "now")),
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
        \\  last_update INTEGER DEFAULT (strftime("%s", "now")),
        \\  last_modified_utc INTEGER DEFAULT NULL,
        \\  etag TEXT DEFAULT NULL,
        \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
        \\);
    , .{ .update_interval = app_config.update_interval }),
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
    const content_type = types.ContentType.rss;
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
    const content_type = types.ContentType.rss;
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
