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

const seconds_in_1_day = std.time.s_per_day;
const seconds_in_3_hours = std.time.s_per_hour * 3;
const seconds_in_6_hours = std.time.s_per_hour * 6;
const seconds_in_12_hours = std.time.s_per_hour * 12;
const seconds_in_2_days = seconds_in_1_day * 2;
const seconds_in_3_days = seconds_in_1_day * 3;
const seconds_in_5_days = seconds_in_1_day * 5;
const seconds_in_7_days = seconds_in_1_day * 7;
const seconds_in_10_days = seconds_in_1_day * 10;
const seconds_in_30_days = seconds_in_1_day * 30;

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

    // Sqlite config for servers: https://kerkour.com/sqlite-for-servers
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
        _ = try db.pragma(void, .{}, "journal_mode", "WAL");
        _ = try db.pragma(void, .{}, "synchronous", "normal");
        _ = try db.pragma(void, .{}, "busy_timeout", "5000");
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

    pub const AddOptions = struct {
        feed_opts: FeedOptions,
        html_opts: ?parse.HtmlOptions = null,
    };
    pub fn addFeed(self: *Self, allocator: Allocator, opts: AddOptions) !usize {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var feed_opts = opts.feed_opts;
        var parsed = try parse.parse(arena.allocator(), feed_opts.body, opts.html_opts);
        if (parsed.feed.title == null) if (feed_opts.title) |new_title| {
            parsed.feed.title = new_title;
        };
        // Faviour favicon from html over rss/atom contents
        if (feed_opts.icon_url) |icon_url| {
            parsed.feed.icon_url = icon_url;
        }

        parsed.feed.feed_url = feed_opts.feed_url;
        parsed.feed_updated_timestamp(feed_opts.feed_updates.last_modified_utc);
        if (opts.html_opts) |_| {
            parsed.feed.page_url = parsed.feed.feed_url;
        }
        try parsed.feed.prepareAndValidate(arena.allocator());
        const feed_id = try self.insertFeed(parsed.feed);
        parsed.feed.feed_id = feed_id;
        if (opts.html_opts) |html_opts| {
            try self.html_selector_add(feed_id, html_opts);
        }
        try parsed.prepareAndValidate(arena.allocator(), feed_opts.feed_updates.last_modified_utc);
        _ = try self.insertFeedItems(parsed.items);
        feed_opts.feed_updates.set_item_interval(parsed.items, null, parsed.feed.updated_timestamp);
        try self.updateFeedUpdate(feed_id, feed_opts.feed_updates);
        return feed_id;
    }

    const curl = @import("curl");
    const ContentType = parse.ContentType;
    pub fn updateFeedAndItems(self: *Self, arena: *std.heap.ArenaAllocator, resp: curl.Easy.Response, feed_info: FeedToUpdate) !void {
        const body = resp.body orelse return error.NoBody;
        const content = body.items;
        var feed_update = FeedUpdate.fromCurlHeaders(resp);

        const feed_id = feed_info.feed_id;
        const html_options = try self.html_selector_get(arena.allocator(), feed_id);
        var parsed = try parse.parse(arena.allocator(), content, html_options);
        parsed.feed.feed_url = feed_info.feed_url;
        parsed.feed.feed_id = feed_id;
        try parsed.prepareAndValidate(arena.allocator(), feed_update.last_modified_utc);

        try self.update_feed_timestamp(parsed.feed);
        try self.rate_limit_remove(feed_id);

        const items_all = parsed.items;
        const timestamp_max = try self.get_timestamp_max(feed_id);
        const id_and_link = blk: {
            if (items_all.len > 0 and items_all[0].updated_timestamp == null) {
                const query = "select id, link from item where feed_id = ? order by position limit 1";
                break :blk try oneAlloc(&self.sql_db, arena.allocator(), IdAndLink, query, .{feed_id});
            }

            break :blk null;
        };
        const timestamp_fallback = parsed.feed.updated_timestamp;
        feed_update.set_item_interval(parsed.items, timestamp_max, timestamp_fallback);
        try self.updateFeedUpdate(feed_id, feed_update);

        const items = try items_prepared(items_all, timestamp_max, id_and_link, timestamp_fallback);
        if (items.len == 0) {
            return;
        }

        try self.updateAndRemoveFeedItems(items);
    }

    pub fn rate_limit_remove(self: *Self, feed_id: usize) !void {
        try self.sql_db.exec("DELETE FROM rate_limit WHERE feed_id = ?", .{}, .{feed_id});
    }

    pub fn rate_limit_add(self: *Self, feed_id: usize, utc_sec: i64) !void {
        try self.sql_db.exec("INSERT OR REPLACE INTO rate_limit (feed_id, utc_sec) VALUES (?, ?)", .{}, .{feed_id, utc_sec});
    }

    pub fn insertFeed(self: *Self, feed: Feed) !usize {
        const query =
            \\INSERT INTO feed (title, feed_url, page_url, icon_url, updated_timestamp)
            \\VALUES (
            \\  @title,
            \\  @feed_url,
            \\  @page_url,
            \\  @icon_url,
            \\  @updated_timestamp
            \\) ON CONFLICT(feed_url) DO NOTHING
            \\RETURNING feed_id;
        ;
        const feed_id = try one(&self.sql_db, usize, query, .{
            .title = feed.title orelse "",
            .feed_url = feed.feed_url,
            .page_url = feed.page_url,
            .icon_url = feed.icon_url,
            .updated_timestamp = feed.updated_timestamp,
        });
        return feed_id orelse Error.FeedExists;
    }

    pub fn get_feed_id_with_url(self: *Self, url: []const u8) !?usize {
        const query =
            \\SELECT feed_id FROM feed WHERE feed_url = ? OR page_url = ?;
        ;
        return try one(&self.sql_db, usize, query, .{ url, url });
    }
    
    pub fn get_feed_with_url(self: *Self, allocator: Allocator, url: []const u8) !?Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, icon_url, updated_timestamp 
            \\FROM feed WHERE feed_url = ? OR page_url = ?;
        ;
        return try oneAlloc(&self.sql_db, allocator, Feed, query, .{ url, url });
    }

    pub fn getFeedsWithUrl(self: *Self, allocator: Allocator, url: []const u8) ![]Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, icon_url, updated_timestamp 
            \\FROM feed WHERE feed_url LIKE '%' || ? || '%' OR page_url LIKE '%' || ? || '%';
        ;
        return try selectAll(&self.sql_db, allocator, Feed, query, .{ url, url });
    }

    pub fn getLatestFeedsWithUrl(self: *Self, allocator: Allocator, inputs: [][]const u8, opts: ShowOptions) ![]Feed {
        const query_start =
            \\SELECT feed_id, title, feed_url, page_url, icon_url, updated_timestamp 
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
        const query = "SELECT 1 from feed where feed_url = ? OR page_url = ?";
        return (try one(&self.sql_db, bool, query, .{url, url})) orelse false;
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

        storage_arr.resize(0) catch unreachable;
        storage_arr.appendSliceAssumeCapacity(query);

        var has_where = false;

        if (!options.force) {
            has_where = true;
            storage_arr.appendSliceAssumeCapacity( 
                \\WHERE ifnull((select strftime('%s', 'now') >= utc_sec from rate_limit where rate_limit.feed_id = feed.feed_id), false)
                \\OR strftime('%s', 'now') - last_update >= item_interval
            );
        }

        if (search_term) |term| {
            if (term.len > 0) {
                const cond_start = if (!has_where) " WHERE " else " AND ";
                storage_arr.appendSliceAssumeCapacity(cond_start);
                storage_arr.appendSliceAssumeCapacity("(feed.feed_url LIKE '%' || ? || '%' OR feed.page_url LIKE '%' || ? || '%' OR feed.title LIKE '%' || ? || '%');");
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

    pub fn update_feed_timestamp(self: *Self, feed: Feed) !void {
        const query =
            \\UPDATE feed SET updated_timestamp = @updated_timestamp 
            \\WHERE feed_id = @feed_id;
        ;
        try self.sql_db.exec(query, .{}, .{ .updated_timestamp = feed.updated_timestamp, .feed_id = feed.feed_id });
    }

    pub const FeedFields = struct {
        feed_id: usize,
        title: []const u8,
        page_url: []const u8,
        icon_url: []const u8,
        tags: [][]const u8,
    };

    pub fn update_feed_fields(self: *Self, allocator: Allocator, fields: FeedFields) !void {
        var savepoint = try self.sql_db.savepoint("update_feed_fields");
        defer savepoint.rollback();

        // Remove tags that aren't part of .tags 
        var buf: [1024]u8 = undefined;
        var buf_cstr: [256]u8 = undefined;

        if (fields.tags.len > 0) {
            var tags_str = std.ArrayList(u8).init(allocator);
            defer tags_str.deinit();

            {
                const tag_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{fields.tags[0]});
                const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                const tag_slice = mem.sliceTo(c_str, 0x0);
                try tags_str.appendSlice(tag_slice);
            }

            for (fields.tags[1..]) |tag| {
                const tag_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{tag});
                const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                const tag_slice = mem.sliceTo(c_str, 0);
                try tags_str.append(',');
                try tags_str.appendSlice(tag_slice);
            }

            const query_fmt = "DELETE FROM feed_tag WHERE feed_id = ? and tag_id not in (select tag_id from tag where name in (?))";
            try self.sql_db.exec(query_fmt, .{}, .{ fields.feed_id, tags_str.items });
        } else {
            const query = "DELETE FROM feed_tag WHERE feed_id = ?";
            try self.sql_db.exec(query, .{}, .{fields.feed_id});
        }

        // Make sure all tags exist
        try self.tags_add(fields.tags);
        for (fields.tags) |tag| {
            const query = 
            \\insert into feed_tag (feed_id, tag_id) values 
            \\  (?, (select tag_id from tag where name = ? limit 1)) ON CONFLICT DO NOTHING
            ;
            try self.sql_db.exec(query, .{}, .{
                fields.feed_id,
                tag,
            });
        }

        const icon_url = blk: {
            const value = mem.trim(u8, fields.icon_url, &std.ascii.whitespace);
            if (value.len == 0) {
                break :blk null;
            }
            break :blk value;
        };

        // Update feed_title and page_url
        const query = 
        \\UPDATE feed 
        \\SET title = ?, page_url = ?, icon_url = ?
        \\WHERE feed_id = ?
        ;
        try self.sql_db.exec(query, .{}, .{
            fields.title,
            fields.page_url,
            icon_url,
            fields.feed_id,
        });

        savepoint.commit();
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

    pub fn updateFeedUpdate(self: *Self, feed_id: usize, feed_update: FeedUpdate) !void {
        const query =
            \\INSERT INTO feed_update 
            \\  (feed_id, update_interval, last_modified_utc, etag, item_interval)
            \\VALUES 
            \\  (@feed_id, @update_interval, @last_modified_utc, @etag, @item_interval)
            \\ ON CONFLICT(feed_id) DO UPDATE SET
            \\  update_interval = @update_interval,
            \\  last_modified_utc = @last_modified_utc,
            \\  etag = @etag,
            \\  item_interval = @item_interval,
            \\  last_update = strftime('%s', 'now')
            \\;
        ;
        try self.sql_db.exec(query, .{}, .{
            .feed_id = feed_id,
            .update_interval = feed_update.update_interval,
            .last_modified_utc = feed_update.last_modified_utc,
            .etag = feed_update.etag,
            .item_interval = feed_update.item_interval,
        });
    }

    pub fn updateLastUpdate(self: *Self, feed_id: usize) !void {
        const query = "update feed_update set last_update = strftime('%s', 'now') where feed_id = @feed_id;";
        try self.sql_db.exec(query, .{}, .{.feed_id = feed_id});
    }

    pub fn add_to_last_update(self: *Self, feed_id: usize, sec: u64) !void {
        const query = "update feed_update set last_update = last_update + ? where feed_id = ?;";
        try self.sql_db.exec(query, .{}, .{sec, feed_id});
    }

    const IdAndLink = struct {
        id: ?[]const u8,
        link: ?[]const u8,
    };
    pub fn updateAndRemoveFeedItems(self: *Self, items: []FeedItem) !void {
        assert(items.len > 0);
        const feed_id = items[0].feed_id;
        {
            const query = "update item set position = position + ? where feed_id = ?;";
            try self.sql_db.exec(query, .{}, .{ items.len, feed_id});
        }
        try self.upsertFeedItems(items);
        try self.cleanFeedItems(feed_id);
    }

    pub fn get_timestamp_max(self: *Self, feed_id: usize) !?i64 {
        const query_item_timestamp = "select max(updated_timestamp) from item where feed_id = ?";
        return try one(&self.sql_db, i64, query_item_timestamp, .{feed_id});
    }

    fn items_prepared(inserts: []FeedItem, timestamp_max: ?i64, id_and_link_opt: ?IdAndLink, fallback_timestamp: ?i64) ![]FeedItem {
        assert(inserts.len > 0);
        var len = inserts.len;

        if (inserts[0].updated_timestamp != null and timestamp_max != null) {
            const timestamp = timestamp_max.?;
            for (inserts, 0..) |item, i| {
                const item_timestamp = item.updated_timestamp orelse continue;
                if (item_timestamp <= timestamp) {
                    len = i;
                    break;
                }
            }
        } else {
            if (id_and_link_opt) |id_and_link| {
                if (id_and_link.id) |id| {
                    for (inserts, 0..) |item, i| {
                        const item_id = item.id orelse continue;
                        if (mem.eql(u8, item_id, id)) {
                            len = i;
                            break;
                        }
                    }
                } else if (id_and_link.link) |link| {
                    for (inserts, 0..) |item, i| {
                        const item_link = item.link orelse continue;
                        if (mem.eql(u8, item_link, link)) {
                            len = i;
                            break;
                        }
                    }
                }
            }

            const ts = fallback_timestamp orelse std.time.timestamp();
            for (inserts[0..len]) |*item| {
                item.*.updated_timestamp = ts;
            }
        }

        const items = inserts[0..len];

        for (items) |*item| {
            if (item.link) |link| {
                item.*.link = std.Uri.percentDecodeInPlace(@constCast(link));
            }
        }

        return items;
    }

    // Initial item table state
    // 1 | Title 1 | 2
    // 2 | Title 2 | 1
    // Update item table
    // ...
    // 3 | Title 3 | 4
    // 4 | Title 4 | 3
    pub fn upsertFeedItems(self: *Self, inserts: []FeedItem) !void {
        assert(inserts.len > 0);

        const query_with_id =
            \\INSERT INTO item (feed_id, title, link, id, updated_timestamp, position)
            \\VALUES (@feed_id, @title, @link, @id, @updated_timestamp, @position)
            \\ON CONFLICT(feed_id, id) DO UPDATE SET
            \\  title = excluded.title,
            \\  link = excluded.link,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position
            \\WHERE 
            \\  updated_timestamp != excluded.updated_timestamp 
            \\  OR position != excluded.position
            \\ON CONFLICT(feed_id, link) DO UPDATE SET
            \\  title = excluded.title,
            \\  id = excluded.id,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position
            \\WHERE
            \\  updated_timestamp != excluded.updated_timestamp 
            \\  OR position != excluded.position
            \\;
        ;

        const query_without_id =
            \\update item set 
            \\  title = @u_title,
            \\  updated_timestamp = @u_timestamp
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

    pub fn cleanFeedItems(self: *Self, feed_id: usize) !void {
        const del_query =
            \\DELETE FROM item WHERE feed_id = ? and position >= ?
        ;
        try self.sql_db.exec(del_query, .{}, .{ feed_id, self.options.max_item_count });
    }

    pub fn feed_items_with_feed_id(self: *Self, alloc: Allocator, feed_id: usize) ![]FeedItemRender {
        const query_item =
            \\select feed_id, title, link, updated_timestamp, created_timestamp
            \\from item where feed_id = ? order by updated_timestamp DESC, position ASC;
        ;
        return try selectAll(&self.sql_db, alloc, FeedItemRender, query_item, .{feed_id});
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

    pub const After = usize;
    pub const Before = usize;
    const FeedSearchArgs = struct {
        tags: [][]const u8 = &.{},
        search: ?[]const u8 = null,
        after: ?After = null,
        before: ?Before = null,
        has_untagged: bool = false,
    };

    fn search_query_where(self: *Self, allocator: Allocator, args: FeedSearchArgs) ![]const u8 {
        assert(
            (args.before == null and args.after == null) or
            (args.before != null and args.after == null) or
            (args.before == null and args.after != null)
        );
        var buf: [1024]u8 = undefined;
        var buf_cstr: [256]u8 = undefined;
        var query_where = try ArrayList(u8).initCapacity(allocator, 1024);
        defer query_where.deinit();
        const where_writer = query_where.writer();

        var has_prev_cond = false;

        if (args.before) |before| {
            const after_fmt =
            \\((updated_timestamp > (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
            \\      OR updated_timestamp > (select updated_timestamp from feed where feed_id = {[id]d}))
            ;

            try where_writer.writeAll("WHERE ");
            try where_writer.print(after_fmt, .{.id = before });
            has_prev_cond = true;
        } else {
            if (args.after) |after| {
                const after_fmt =
                \\((updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
                \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}))
                ;

                try where_writer.writeAll("WHERE ");
                try where_writer.print(after_fmt, .{.id = after });
                has_prev_cond = true;
            }
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
            if (value_trimmed.len > 0) {
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

                const value_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{value_trimmed});
                const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", value_cstr.ptr);
                const search = mem.sliceTo(c_str, 0);

                try where_writer.print(search_fmt, .{.search_value = search });
                has_prev_cond = true;
            }
        }
        
        return query_where.toOwnedSlice();
    }

    pub fn feeds_search_complex(self: *Self, allocator: Allocator, args: FeedSearchArgs) ![]types.FeedRender {
        assert(
            (args.before == null and args.after == null) or
            (args.before != null and args.after == null) or
            (args.before == null and args.after != null)
        );
        var savepoint = try self.sql_db.savepoint("search_complex");
        defer savepoint.rollback();


        const query_where = try self.search_query_where(allocator, args);
        defer allocator.free(query_where);
        const query_fmt = 
        \\SELECT * FROM feed {s}
        \\ORDER BY updated_timestamp DESC, feed_id DESC LIMIT
        ++ comptimePrint(" {d}", .{app_config.query_feed_limit})
        ;
        const query = try std.fmt.allocPrint(allocator, query_fmt, .{query_where});
        var stmt = try self.sql_db.prepareDynamic(query);
        defer stmt.deinit();
        const result =  try stmt.all(types.FeedRender, allocator, .{}, .{});
        savepoint.commit();
        return result;
    }

    pub fn feeds_search_has_previous(self: *Self, allocator: Allocator, args: FeedSearchArgs) !bool {
        assert(args.before != null);

        const query_where = try self.search_query_where(allocator, args);
        defer allocator.free(query_where);
        const query_fmt = 
        \\SELECT 1 FROM feed {s}
        \\ORDER BY updated_timestamp DESC, feed_id DESC LIMIT 1
        ;
        const query = try std.fmt.allocPrint(allocator, query_fmt, .{query_where});
        defer allocator.free(query);
        var stmt = try self.sql_db.prepareDynamic(query);
        defer stmt.deinit();
        const result =  try stmt.one(bool, .{}, .{});
        return result orelse false;
    }
    
    const after_cond_raw =
    \\AND ((updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
    \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d})) 
    ;

    pub fn feeds_tagless(self: *Self, allocator: Allocator) ![]types.FeedRender {
        const query_fmt = 
        \\select * from feed where feed_id not in (
        \\  select distinct(feed_id) from feed_tag
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

    // const InsertRuleHost = struct {
    //     name: []const u8,
    // };

    // const InsertAddRule = struct {
    //     match_host_id: usize,
    //     match_path: []const u8,
    //     result_host_id: usize,
    //     result_path: []const u8,
    // };

    const Rule = @import("add_rule.zig").Rule;
    pub fn rule_add(self: *Self, rule: Rule) !void {
        const query_insert_host =
        \\INSERT OR IGNORE INTO add_rule_host(name) VALUES (?) RETURNING host_id;
        ;
        const query_select_host = "SELECT host_id FROM add_rule_host WHERE name = ?";
        const name = rule.match_host;
        const host_id = try one(&self.sql_db, usize, query_insert_host, .{name}) 
            orelse try one(&self.sql_db, usize, query_select_host, .{name})
            orelse return error.CouldNotGetAddRuleHostId;

        const query_insert_rule = 
        \\insert or ignore into 
        \\  add_rule(match_host_id, match_path, result_host_id, result_path) 
        \\  values (?, ?, ?, ?);
        ;
        try self.sql_db.exec(query_insert_rule, .{}, .{host_id, rule.match_path, host_id, rule.result_path});
    }

    const AddRule = @import("add_rule.zig");
    pub fn get_rules_for_host(self: *Self, allocator: Allocator, host: []const u8) ![]AddRule.RuleWithHost {
        const query_select_host = "SELECT host_id FROM add_rule_host WHERE name = ?";
        const host_id = (try one(&self.sql_db, usize, query_select_host, .{host})) orelse return &.{};
        const query = 
        \\select 
        \\  match_path,
        \\  (select name from add_rule_host where host_id = add_rule.result_host_id) as result_host, 
        \\  result_path
        \\from add_rule 
        \\where match_host_id = ?;
        ;

        return try selectAll(&self.sql_db, allocator, AddRule.RuleWithHost, query, .{host_id});
    }

    pub fn get_add_rule(self: *Self, allocator: Allocator, uri: std.Uri) !?Rule {
        const query_select_host = "SELECT host_id FROM add_rule_host WHERE name = ?";
        const host_id = (try one(&self.sql_db, usize, query_select_host, .{uri.host})) orelse return null;

        const query = 
        \\select 
        \\  (select name from add_rule_host where host_id = @host_id) as match_host, 
        \\  match_path, 
        \\  (select name from add_rule_host where host_id = @host_id) as result_host, 
        \\  result_path 
        \\from add_rule 
        \\where match_host_id = @host_id AND match_path like @tmp_path;
        ;

        const tmp_path = try allocator.dupe(u8, uri.path);
        mem.replaceScalar(u8, tmp_path, '*', '%');
        print("path: {s}\n", .{tmp_path});
        return try oneAlloc(&self.sql_db, allocator, Rule, query, .{. host_id = host_id, .tmp_path = tmp_path});
    }

    pub fn update_item_intervals(self: *Self) !void {
        // Maybe can change query using sqlite fn nth_value(), first_value(), lead(), lag()?
        const query = comptimePrint(
            \\with temp_table as (
            \\  select feed.feed_id, coalesce(max(item.updated_timestamp) - 
            \\    (select this.updated_timestamp from item as this where this.feed_id = feed.feed_id order by this.updated_timestamp DESC limit 1, 1), {d}
            \\  ) item_interval
            \\  from feed 
            \\  left join item on feed.feed_id = item.feed_id and item.updated_timestamp is not null
            \\  group by item.feed_id
            \\)    
            \\update feed_update set item_interval = (
            \\CASE
            \\  when temp_table.item_interval < {d} then {d}
            \\  when temp_table.item_interval < {d} then {d}
            \\  when temp_table.item_interval < {d} then {d}
            \\  when temp_table.item_interval < {d} then {d}
            \\  when temp_table.item_interval < {d} then {d}
            \\  when temp_table.item_interval < {d} then {d}
            \\  else {d}
            \\end
            \\) from temp_table where feed_update.feed_id = temp_table.feed_id
            \\AND feed_update.item_interval != temp_table.item_interval;
        , .{
            // In case item count is 0 or 1 make sure case expressions else branch
            // is hit.
            seconds_in_30_days, 

            // else case with item_interval
            seconds_in_6_hours, seconds_in_3_hours,
            seconds_in_12_hours, seconds_in_6_hours,
            seconds_in_1_day, seconds_in_12_hours,
            seconds_in_2_days, seconds_in_1_day,
            seconds_in_7_days, seconds_in_3_days,
            seconds_in_30_days, seconds_in_5_days,
            seconds_in_10_days,
        });
        try self.sql_db.exec(query, .{}, .{});
    }

    // Negative numbers means can be updated right now
    // Positive number is countdown till update
    pub fn next_update_countdown(self: *Self) !?i64 {
        const query = 
        \\select min(
        \\  (select ifnull(min(utc_sec), 9223372036854775807) from rate_limit),
        \\  (select min(last_update + item_interval) from feed_update where feed_id not in (select feed_id from rate_limit))
        \\) - strftime('%s', 'now')
        ;
        return try one(&self.sql_db, i64, query, .{});
    }

    pub fn next_update_feed(self: *Self, feed_id: usize) !?i64 {
        const query = 
        \\select 
        \\  coalesce(
        \\    (select utc_sec from rate_limit where feed_id = feed_update.feed_id), 
        \\    last_update + item_interval
        \\  ) - strftime('%s', 'now')
        \\from feed_update where feed_update.feed_id = ?;
        ;
        return try one(&self.sql_db, i64, query, .{feed_id});
    }

    pub fn feed_last_update(self: *Self, feed_id: usize) !?i64 {
        return try one(&self.sql_db, i64, "select last_update from feed_update where feed_id = ?", .{feed_id});
    }

    pub fn get_items_latest_added(self: *Self, allocator: Allocator) ![]FeedItemRender {
        const query = 
        \\SELECT feed_id, title, link, updated_timestamp, created_timestamp
        \\FROM item WHERE created_timestamp > strftime("%s", "now", "-3 days") ORDER BY created_timestamp DESC
        ;
        return try selectAll(&self.sql_db, allocator, FeedItemRender, query, .{});
    }

    pub fn get_latest_change(self: *Self) !?i64 {
        const query = 
            \\select max(
            \\  (SELECT max(created_timestamp) FROM item),
            \\  (SELECT max(last_update) FROM feed_update)
            \\);
        ;
        return try one(&self.sql_db, i64, query, .{});
    }

    pub fn get_latest_feed_change(self: *Self, feed_id: usize) !?i64 {
        const query = 
            \\SELECT max(created_timestamp) FROM item
            \\WHERE feed_id = ?;
        ;
        return try one(&self.sql_db, i64, query, .{feed_id});
    }

    pub fn get_feeds_with_ids(self: *Self, allocator: Allocator, ids: []const usize) ![]types.Feed {
        std.debug.assert(ids.len > 0);
        var query_al = try std.ArrayList(u8).initCapacity(allocator, 256);
        query_al.appendSliceAssumeCapacity(
            \\select feed_id, title, feed_url, page_url, icon_url, updated_timestamp from feed where feed_id in (
        );
        // u64 numbers max length
        var buf: [20]u8 = undefined;
        var id_str = try std.fmt.bufPrint(&buf, "{d}", .{ids[0]});
        try query_al.appendSlice(id_str);
        for (ids[1..]) |id| {
            id_str = try std.fmt.bufPrint(&buf, ",{d}", .{id});
            try query_al.appendSlice(id_str);
        }
        try query_al.append(')');

        var stmt = try self.sql_db.prepareDynamic(query_al.items);
        defer stmt.deinit();
        return try stmt.all(types.Feed, allocator, .{}, .{});
    }

    pub const FeedIcon = struct {
        feed_id: usize,
        page_url: []const u8,
    };

    pub fn feed_icons_all(self: *Self, allocator: Allocator) ![]FeedIcon {
        const query =
        \\SELECT feed_id, page_url 
        \\FROM feed where page_url IS NOT NULL
        ;
        return try selectAll(&self.sql_db, allocator, FeedIcon, query, .{});
    }

    pub fn feed_icons_missing(self: *Self, allocator: Allocator) ![]FeedIcon {
        const query =
        \\SELECT feed_id, page_url 
        \\FROM feed WHERE icon_url IS NULL AND page_url IS NOT NULL
        ;
        return try selectAll(&self.sql_db, allocator, FeedIcon, query, .{});
    }

    pub fn feed_icon_update(self: *Self, feed_id: usize, icon_url: []const u8) !void {
        const query = 
        \\UPDATE feed SET
        \\  icon_url = ?
        \\WHERE feed_id = ?;
        ;
        try self.sql_db.exec(query, .{}, .{icon_url, feed_id});
    }

    pub fn html_selector_add(self: *Self, feed_id: usize, options: parse.HtmlOptions) !void {
        const query =
            \\INSERT INTO html_selector (feed_id, container, link, heading, date, date_format)
            \\VALUES (
            \\  @feed_id,
            \\  @container,
            \\  @link,
            \\  @heading,
            \\  @date,
            \\  @date_format
            \\) ON CONFLICT(feed_id) DO UPDATE SET
            \\  container = @container,
            \\  link = @link,
            \\  heading = @heading,
            \\  date = @date,
            \\  date_format = @date_format
            \\;
        ;

        try self.sql_db.exec(query, .{}, .{
            .feed_id = feed_id,
            .container = options.selector_container,
            .link = options.selector_link,
            .heading = options.selector_heading,
            .date = options.selector_date,
            .date_format = options.date_format,
        });
    }

    pub fn html_selector_get(self: *Self, allocator: Allocator, feed_id: usize) !?parse.HtmlOptions {
        const query = 
        \\select 
        \\ container as selector_container,
        \\ link as selector_container,
        \\ heading as selector_heading,
        \\ date as selector_date,
        \\ date_format
        \\from html_selector
        \\where feed_id = ?;
        ;
        return try oneAlloc(&self.sql_db, allocator, parse.HtmlOptions, query, .{feed_id});
    }
};

// TODO: feed.title default value should be null
const tables = &[_][]const u8{
    \\CREATE TABLE IF NOT EXISTS feed(
    \\  feed_id INTEGER PRIMARY KEY,
    \\  title TEXT NOT NULL,
    \\  feed_url TEXT NOT NULL UNIQUE,
    \\  page_url TEXT DEFAULT NULL,
    \\  icon_url TEXT DEFAULT NULL,
    \\  updated_timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS item(
    \\  item_id INTEGER PRIMARY KEY,
    \\  feed_id INTEGER NOT NULL,
    \\  title TEXT NOT NULL,
    \\  link TEXT DEFAULT NULL,
    \\  id TEXT DEFAULT NULL,
    \\  updated_timestamp INTEGER DEFAULT NULL,
    \\  position INTEGER NOT NULL DEFAULT 0,
    \\  created_timestamp INTEGER DEFAULT (strftime('%s', 'now')),
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE,
    \\  UNIQUE(feed_id, id),
    \\  UNIQUE(feed_id, link)
    \\) STRICT;
    ,
    comptimePrint(
        \\CREATE TABLE IF NOT EXISTS feed_update (
        \\  feed_id INTEGER UNIQUE NOT NULL,
        \\  update_interval INTEGER NOT NULL DEFAULT {d},
        \\  item_interval INTEGER NOT NULL DEFAULT {d},
        \\  last_update INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        \\  last_modified_utc INTEGER DEFAULT NULL,
        \\  etag TEXT DEFAULT NULL,
        \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
        \\) STRICT;
    , .{ app_config.update_interval, seconds_in_10_days }),
    \\CREATE TABLE IF NOT EXISTS tag(
    \\  tag_id INTEGER PRIMARY KEY,
    \\  name TEXT UNIQUE NOT NULL
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS feed_tag(
    \\  tag_id INTEGER NOT NULL,
    \\  feed_id INTEGER NOT NULL,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE,
    \\  FOREIGN KEY(tag_id) REFERENCES tag(tag_id) ON DELETE CASCADE,
    \\  UNIQUE(tag_id, feed_id)
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS add_rule_host(
    \\  host_id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL UNIQUE
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS add_rule(
    \\  add_rule_id INTEGER PRIMARY KEY,
    \\  match_host_id INTEGER NOT NULL,
    \\  match_path TEXT NOT NULL,
    \\  result_host_id INTEGER NOT NULL,
    \\  result_path TEXT NOT NULL,
    \\  FOREIGN KEY(match_host_id) REFERENCES add_rule_host(host_id),
    \\  FOREIGN KEY(result_host_id) REFERENCES add_rule_host(host_id),
    \\  UNIQUE(match_host_id, match_path)
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS rate_limit(
    \\  feed_id INTEGER UNIQUE NOT NULL,
    \\  utc_sec INTEGER NOT NULL DEFAULT 3600,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS html_selector(
    \\  feed_id INTEGER UNIQUE NOT NULL,
    \\  container TEXT NOT NULL,
    \\  link TEXT DEFAULT NULL,
    \\  heading TEXT DEFAULT NULL,
    \\  date TEXT DEFAULT NULL,
    \\  date_format TEXT DEFAULT NULL,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
    \\) STRICT;
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
