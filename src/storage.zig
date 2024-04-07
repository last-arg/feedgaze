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

    // TODO: use feed_opts.feed_url
    pub fn addFeed(self: *Self, arena: *std.heap.ArenaAllocator, feed_opts: FeedOptions) !usize {
        var parsed = try parse.parse(arena.allocator(), feed_opts.body, feed_opts.content_type);
        if (parsed.feed.title == null) {
            parsed.feed.title = feed_opts.title orelse "";
        }
        parsed.feed.feed_url = feed_opts.feed_url;
        parsed.feed_updated_timestamp();
        const feed_id = try self.insertFeed(parsed.feed);
        parsed.feed.feed_id = feed_id;
        try parsed.prepareAndValidate(arena.allocator());
        _ = try self.insertFeedItems(parsed.items);
        try self.updateFeedUpdate(feed_id, feed_opts.feed_updates);
        return feed_id;
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
        parsed.feed.feed_url = feed_info.feed_url;
        parsed.feed.feed_id = feed_info.feed_id;
        try parsed.prepareAndValidate(arena.allocator());

        try self.updateFeed(parsed.feed);
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
            .title = feed.title orelse "",
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

    // TODO: also add title to search from
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
        assert(feed.feed_url.len > 0);
        if (!try self.hasFeedWithId(feed.feed_id)) {
            return Error.FeedNotFound;
        }
        // TODO: should I set feed_url also? In case feed_url has changed?
        const query =
            \\UPDATE feed SET
            \\  title = @title,
            \\  page_url = @page_url,
            \\  updated_timestamp = @updated_timestamp
            \\WHERE feed_id = @feed_id;
        ;
        const values = .{
            .feed_id = feed.feed_id,
            .title = feed.title,
            .page_url = feed.page_url,
            .updated_timestamp = feed.updated_timestamp,
        };
        try self.sql_db.exec(query, .{}, values);
    }

    pub fn hasFeedWithId(self: *Self, feed_id: usize) !bool {
        const exists_query = "SELECT EXISTS(SELECT 1 FROM feed WHERE feed_id = ?)";
        return (try one(&self.sql_db, bool, exists_query, .{feed_id})).?;
    }

    pub fn insertFeedItems(self: *Self, inserts: []FeedItem) ![]FeedItem {
        if (inserts.len == 0) {
            return &.{};
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
            return;
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

    pub fn feeds_page(self: *Self, alloc: Allocator, after: ?After) ![]types.FeedRender {
        if (after) |feed_id| {
            const query = comptimePrint(
                \\select * from feed 
                \\where (updated_timestamp < (select updated_timestamp from feed where feed_id = ?) AND feed_id < ?)
                \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = ?) 
                \\order by updated_timestamp DESC, feed_id DESC limit {d};
            , .{app_config.query_feed_limit});
            const args = .{feed_id, feed_id, feed_id};
            return try selectAll(&self.sql_db, alloc, types.FeedRender, query, args);
        } else {
            const query =
                "select * from feed order by updated_timestamp DESC, feed_id DESC LIMIT " ++ comptimePrint("{d}", .{app_config.query_feed_limit});
            return try selectAll(&self.sql_db, alloc, types.FeedRender, query, .{});
        }
    }

    pub fn feeds_search(self: *Self, alloc: Allocator, search_term: []const u8, after: ?After) ![]types.FeedRender {
        const query_base =
            \\select * from feed 
            \\where {s} (
            \\  feed.title LIKE '%' || ? || '%' OR
            \\  feed.page_url LIKE '%' || ? || '%' OR
            \\  feed.feed_url LIKE '%' || ? || '%' 
            \\) LIMIT
            ++ comptimePrint(" {d}", .{app_config.query_feed_limit})
        ;
        const query_search = comptimePrint(query_base, .{""});
        const partial = "updated_timestamp < (select updated_timestamp from feed where feed_id = ?) AND";
        const query_after = comptimePrint(query_base, .{partial});
        if (after) |feed_id| {
            return try selectAll(&self.sql_db, alloc, types.FeedRender, query_after, .{feed_id, search_term, search_term, search_term});
        } else {
            return try selectAll(&self.sql_db, alloc, types.FeedRender, query_search, .{search_term, search_term, search_term});
        }
    }
    
    pub fn tags_all(self: *Self, alloc: Allocator) ![][]const u8 {
        const query = "SELECT name FROM tag ORDER BY name ASC;";
        return try selectAll(&self.sql_db, alloc, []const u8, query, .{});
    }

    const TagResult = struct{tag_id: usize, name: []const u8};
    pub fn tags_all_with_ids(self: *Self, alloc: Allocator) ![]TagResult {
        const query = "select * from tag order by name ASC;";
        return try selectAll(&self.sql_db, alloc, TagResult, query, .{});
    }

    pub fn tags_remove_keep(self: *Self, allocator_in: Allocator, feed_id: usize, tag_ids: []usize) !void {
        std.debug.assert(tag_ids.len >= 0);
        var arena = std.heap.ArenaAllocator.init(allocator_in);
        const allocator = arena.allocator();
        defer arena.deinit();

        const query_fmt = "DELETE FROM feed_tag WHERE feed_id = ? and tag_id not in ([tag_ids])";
        var query_dyn = try std.ArrayList(u8).initCapacity(allocator, tag_ids.len * 10);
        defer query_dyn.deinit();
        var iter = std.mem.splitSequence(u8, query_fmt, "[tag_ids]");
        const query_begin = iter.next() orelse unreachable;
        const query_end = iter.next() orelse unreachable;
        std.debug.assert(iter.next() == null);

        try query_dyn.appendSlice(query_begin);
        {
            const str = try std.fmt.allocPrint(allocator, "{d}", .{tag_ids[0]});
            try query_dyn.appendSlice(str);
        }
        for (tag_ids[1..]) |tag_id| {
            const str = try std.fmt.allocPrint(allocator, ",{d}", .{tag_id});
            try query_dyn.appendSlice(str);
        }
        try query_dyn.appendSlice(query_end);

        var stmt = try self.sql_db.prepareDynamic(query_dyn.items);
        defer stmt.deinit();
        return try stmt.exec(.{}, .{feed_id});
    }

    pub fn feed_tags(self: *Self, alloc: Allocator, feed_id: usize) ![][]const u8 {
        const query = 
        \\select name from tag where tag_id in (
        \\  select distinct(tag_id) from feed_tag where feed_id = ?
        \\)
        ;
        return try selectAll(&self.sql_db, alloc, []const u8, query, .{feed_id});
    }
        
    pub fn tags_add(self: *Self, tags: [][]const u8) !void {
        const query = "INSERT INTO tag (name) VALUES(?) ON CONFLICT DO NOTHING;";
        for (tags) |tag| {
            assert(tags.len > 0);
            try self.sql_db.exec(query, .{}, .{tag});
        }
    }

    pub fn tags_ids(self: *Self, tags: [][]const u8, buf: []usize) ![]usize {
        const query = "select tag_id from tag where name = ?;"; 
        var i: usize = 0;
        for (tags) |tag| {
            if (try one(&self.sql_db, usize, query, .{tag})) |value| {
                std.debug.print("id: {d}", .{value});
                buf[i] = value;
                i += 1;
            }
        }
        return buf[0..i];
    }

    pub fn tags_remove(self: *Self, tags: [][]const u8) !void {
        const query = "DELETE FROM tag WHERE name = ?";
        for (tags) |tag| {
            assert(tag.len > 0);
            try self.sql_db.exec(query, .{}, .{tag});
        }
    }

    pub fn tags_feed_add(self: *Self, feed_id: usize, tag_ids: []usize) !void {
        const query = "INSERT INTO feed_tag (feed_id, tag_id) VALUES (?, ?) ON CONFLICT DO NOTHING";
        for (tag_ids) |tag_id| {
            try self.sql_db.exec(query, .{}, .{feed_id, tag_id});
        }
    }

    pub fn tags_feed_remove(self: *Self, feed_id: usize, tag_ids: []usize) !void {
        const query = "DELETE FROM feed_tag WHERE feed_id = ? AND tag_id = ?;";
        for (tag_ids) |tag_id| {
            try self.sql_db.exec(query, .{}, .{feed_id, tag_id});
        }
    }

    pub fn feeds_with_tags(self: *Self, allocator: Allocator, tags: [][]const u8, after: ?After) ![]types.FeedRender {
        if (tags.len == 0) { return &.{}; }
        const query_fmt = 
        \\SELECT * FROM feed WHERE feed_id IN (
        \\	SELECT distinct(feed_id) FROM feed_tag WHERE tag_id IN (
        \\		SELECT tag_id FROM tag where name in ({s})
        \\	) {s}
        \\) ORDER BY updated_timestamp DESC, feed_id DESC LIMIT
        ++ comptimePrint(" {d}", .{app_config.query_feed_limit})
        ;

        const after_cond = blk: {
            if (after) |feed_id| {
                break :blk try std.fmt.allocPrint(allocator, after_cond_raw, .{.id = feed_id});
            }
            break :blk null;
        };
        defer if (after_cond) |slice| allocator.free(slice);

        var query_arr = try std.ArrayList(u8).initCapacity(allocator, tags.len * 2);
        query_arr.appendAssumeCapacity('?');
        for (tags[1..]) |_| {
            query_arr.appendSliceAssumeCapacity(",?");
        }
        const query = try std.fmt.allocPrint(allocator, query_fmt, .{query_arr.items, after_cond orelse ""});
        var stmt = try self.sql_db.prepareDynamic(query);
        defer stmt.deinit();
        return try stmt.all(types.FeedRender, allocator, .{}, tags);
    }

    pub fn feeds_untagged(self: *Self, allocator: Allocator) ![]types.FeedRender {
        const query_fmt = 
        \\SELECT * FROM feed WHERE feed_id NOT IN (
        \\	SELECT distinct(feed_id) FROM feed_tag
        \\) ORDER BY updated_timestamp DESC, feed_id DESC LIMIT
        ++ comptimePrint(" {d}", .{app_config.query_feed_limit})
        ;

        const query = query_fmt;
        var stmt = try self.sql_db.prepareDynamic(query);
        defer stmt.deinit();
        return try stmt.all(types.FeedRender, allocator, .{}, .{});
    }

    pub const After = usize;
    const FeedSearchArgs = struct {
        tags: [][]const u8 = &.{},
        search: ?[]const u8 = null,
        after: ?After = null,
        has_untagged: bool = false,
    };
    pub fn feeds_search_complex(self: *Self, allocator: Allocator, args: FeedSearchArgs) ![]types.FeedRender {
        var buf: [1024]u8 = undefined;
        var buf_cstr: [256]u8 = undefined;
        var query_where = try ArrayList(u8).initCapacity(allocator, 1024);
        defer query_where.deinit();
        const where_writer = query_where.writer();

        var has_prev_cond = false;

        if (args.after) |after| {
            const after_fmt =
            \\((updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
            \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}))
            ;

            try where_writer.writeAll("WHERE ");
            try where_writer.print(after_fmt, .{.id = after });
            has_prev_cond = true;
        }

        
        const ids_tag = blk: {
            if (args.tags.len > 0) {
                var tags_str = std.ArrayList(u8).init(allocator);
                defer tags_str.deinit();

                {
                    const tag_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{args.tags[0]});
                    const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                    const tag_slice = mem.sliceTo(c_str, 0x0);
                    try tags_str.appendSlice(tag_slice);
                }

                for (args.tags[1..]) |tag| {
                    const tag_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{tag});
                    const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                    const tag_slice = mem.sliceTo(c_str, 0);
                    try tags_str.append(',');
                    try tags_str.appendSlice(tag_slice);
                }

                const query_fmt = "SELECT tag_id FROM tag where name in ({s})";
                const query = try std.fmt.allocPrint(allocator, query_fmt, .{tags_str.items});
                var stmt = try self.sql_db.prepareDynamic(query);
                defer stmt.deinit();
                break :blk try stmt.all(usize, allocator, .{}, .{});
            }
            break :blk &.{};
        };
        defer if (ids_tag.len > 0) allocator.free(ids_tag);

        if (ids_tag.len > 0 or args.has_untagged) {
            if (has_prev_cond) {
                try where_writer.writeAll(" AND ");
            } else {
                try where_writer.writeAll("WHERE ");
            }

            try where_writer.writeAll("(");
            if (ids_tag.len > 0) {
                try where_writer.writeAll("feed_id in (");
                try where_writer.writeAll("SELECT distinct(feed_id) FROM feed_tag WHERE tag_id IN (");
                try where_writer.print("{d}", .{ids_tag[0]});
                for (ids_tag[1..]) |id| {
                    try where_writer.print(",{d}", .{id});
                }
                try where_writer.writeAll(")");
                try where_writer.writeAll(")");
            }

            if (args.has_untagged) {
                if (ids_tag.len > 0) {
                    try where_writer.writeAll(" OR ");
                }
                const query_untagged = "feed_id NOT IN (SELECT distinct(feed_id) FROM feed_tag)";
                try where_writer.writeAll(query_untagged);
            }

            try where_writer.writeAll(")");
            has_prev_cond = true;
        }
        
        if (args.search) |value| {
            const value_trimmed = mem.trim(u8, value, &std.ascii.whitespace);
            std.debug.assert(value_trimmed.len > 0);
            const search_fmt =
                \\(
                \\  feed.title LIKE '%' || {[search_value]s} || '%' OR
                \\  feed.page_url LIKE '%' || {[search_value]s} || '%' OR
                \\  feed.feed_url LIKE '%' || {[search_value]s} || '%' 
                \\) 
            ;

            if (has_prev_cond) {
                try where_writer.writeAll(" AND ");
            } else {
                try where_writer.writeAll("WHERE ");
            }

            const value_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{value});
            const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", value_cstr.ptr);
            const search = mem.sliceTo(c_str, 0);
            std.debug.print("serach_value: |{s}|\n", .{search});

            try where_writer.print(search_fmt, .{.search_value = search });
            has_prev_cond = true;
        }

        const query_fmt = 
        \\SELECT * FROM feed {s}
        \\ORDER BY updated_timestamp DESC, feed_id DESC LIMIT
        ++ comptimePrint(" {d}", .{app_config.query_feed_limit})
        ;
        const query = try std.fmt.allocPrint(allocator, query_fmt, .{query_where.items});
        var stmt = try self.sql_db.prepareDynamic(query);
        defer stmt.deinit();
        return try stmt.all(types.FeedRender, allocator, .{}, .{});
    }
    
    const after_cond_raw =
    \\AND ((updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
    \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d})) 
    ;

    pub fn feeds_search_with_tags(self: *Self, allocator: Allocator, search_value: []const u8, tags: [][]const u8, after: ?After) ![]types.FeedRender {
        assert(search_value.len > 0);
        assert(tags.len > 0);
        return try self.feeds_search_complex(allocator, .{
            .tags = tags,
            .after = after,
            .search = search_value,
        });
    }

    pub fn feeds_tagless(self: *Self, allocator: Allocator) ![]types.FeedRender {
        const query_fmt = 
        \\select * from feed where feed_id not in (
        \\	select distinct(feed_id) from feed_tag
        \\) order by updated_timestamp DESC;
        ;
        return try selectAll(&self.sql_db, allocator, types.FeedRender, query_fmt, .{});
    }

    pub fn feed_with_id(self: *Self, allocator: Allocator, id: usize) !?types.FeedRender {
        const query = "select * from feed where feed_id = ?";
        return oneAlloc(&self.sql_db, allocator, types.FeedRender, query, .{id});
    }

    const FeedModifty = struct {
        feed_id: usize,
        title: []const u8,
        page_url: ?[]const u8,
    };
    pub fn feed_modify(self: *Self, feed: FeedModifty) !void {
        const query =
            \\UPDATE feed SET
            \\  title = @title,
            \\  page_url = @page_url
            \\WHERE feed_id = @feed_id;
        ;
        try self.sql_db.exec(query, .{}, feed);
    }
};

// TODO: feed.title default value should be null
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
    \\CREATE TABLE IF NOT EXISTS tag(
    \\  tag_id INTEGER PRIMARY KEY,
    \\  name TEXT UNIQUE NOT NULL
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS feed_tag(
    \\  tag_id INTEGER NOT NULL,
    \\  feed_id INTEGER NOT NULL,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE,
    \\  FOREIGN KEY(tag_id) REFERENCES tag(tag_id) ON DELETE CASCADE,
    \\  UNIQUE(tag_id, feed_id)
    \\)
    ,
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var storage = try Storage.init("./tmp/feeds.db");
    var tags = [_][]const u8{"programming"};
    const result = try storage.feeds_search_complex(arena.allocator(), .{
        .tags = &tags,
        // .after = 4,
        .search = "prog",
        .has_untagged = true,
    });
    print("result.len: {d}\n", .{result.len});
    print("result.id: {d}\n", .{result[0].feed_id});
}
