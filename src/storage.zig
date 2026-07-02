    const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const types = @import("./feed_types.zig");
const Feed = types.Feed;
const Icon = types.IconRender;
const FeedItem = types.FeedItem;
const FeedItemRender = types.FeedItemRender;
const FeedUpdate = types.FeedUpdate;
const FeedToUpdate = types.FeedToUpdate;
const FeedOptions = types.FeedOptions;
const sql = @import("fridge");
const print = std.debug.print;
const comptimePrint = std.fmt.comptimePrint;
const ShowOptions = types.ShowOptions;
const UpdateOptions = types.UpdateOptions;
const parse = @import("./feed_parse.zig");
const app_config = @import("app_config.zig");
const util = @import("util.zig"); 
const is_url = util.is_url; 
const is_url_or_data = util.is_url_or_data; 

pub const Storage = struct {
    const Self = @This();
    sql_db: sql.Session,
    allocator: Allocator,
    options: Options = .{},

    var buffer: [4096]u8 = undefined;
    var storage_arr = std.ArrayListUnmanaged(u8).initBuffer(&buffer);

    const Options = struct {
        max_item_count: usize = app_config.max_items,
    };

    pub const Error = error{
        FeedNotFound,
        FeedItemNotFound,
        NotFound,
        FeedExists,
    };

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: ?[:0]const u8) !Self {
        const filename = if (path) |p| p else ":memory:";
        var db = try sql.Session.open(sql.SQLite3, allocator, io, .{ .filename = filename });
        errdefer db.deinit();

        try setupDb(&db);

        return .{
            .sql_db = db,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.sql_db.deinit();
    }

    pub inline fn free(self: *Self, memory: anytype) void {
        self.allocator.free(memory);
    }

    // Sqlite config for servers: https://kerkour.com/sqlite-for-servers
    fn setupDb(db: *sql.Session) !void {
        errdefer std.log.err("Failed to create new database", .{});

        // NOTE: permanent pragmas:
        // - application_id
        // - journal_mode (when enabling or disabling WAL mode)
        // - schema_version
        // - user_version
        // - wal_checkpoint
        try db.conn.execAll("PRAGMA foreign_keys = 1");
        try db.conn.execAll("PRAGMA journal_mode = WAL");
        try db.conn.execAll("PRAGMA synchronous = normal");
        try db.conn.execAll("PRAGMA temp_store = 2");
        try db.conn.execAll("PRAGMA mmap_size = 30000000000");
        try db.conn.execAll("PRAGMA cache_size = -32000");

        // TODO: replace with sql.migrate()
        try setupTables(db);
        try initData(db);
    }

    fn setupTables(db: *sql.Session) !void {
        errdefer std.log.err("Failed to create database tables", .{});
        inline for (tables) |query| {
            db.conn.execAll(query) catch |err| {
                print_sql_error(db, query);
                return err;
            };
        }
    }

    fn print_sql_error(db: *sql.Session, query: []const u8) void {
        std.log.err("SQL_ERROR: {s}\n Failed query:\n{s}\n", .{ db.conn.lastError(), query });
    }

    fn initData(db: *sql.Session) !void {
        // TODO: move this to where table_last_update table is created?
        const query =
        \\INSERT OR IGNORE INTO table_last_update (table_name) 
        \\VALUES 
        \\  ('tag'),
        \\  ('feed');
        ;
        db.conn.execAll(query) catch |err| {
            std.log.err("Failed to fill in database initial data", .{});
            print_sql_error(db, query);
            return err;
        };
    }

    pub const AddOptions = struct {
        feed_opts: FeedOptions,
    };

    pub const AddFeed = struct {
        feed_id: Feed.ID,
        icon_id: Icon.ID,
    };

    pub fn addFeed(self: *Self, parsed_feed: parse.ValidFeed, opts: AddOptions) !AddFeed {
        var parsed = parsed_feed;
        const feed_opts = opts.feed_opts;

        if (feed_opts.icon) |icon| {
            parsed.feed.icon_id = try self.icon_upsert(icon);
        }

        const feed_id = try self.insertFeed(parsed.feed);
        parsed.feed.feed_id = feed_id;
        if (parsed.html_opts) |html_opts| {
            assert(feed_opts.content_type == .html);
            try self.html_selector_add(feed_id, html_opts);
        }

        for (parsed.items) |*item| {
            item.*.feed_id = feed_id;
        }
         
        _ = try self.insertFeedItems(parsed.items);
        try self.updateFeedUpdate(feed_id, feed_opts.feed_updates, parsed.item_interval);
        return .{.feed_id = feed_id, .icon_id = parsed.feed.icon_id};
    }

    const ContentType = parse.ContentType;
    pub fn updateFeedAndItems(
        self: *Self,
        parsed: parse.ValidFeed,
        feed_update_input: FeedUpdate,
    ) !void {
        const feed_id = parsed.feed.feed_id;
        try self.update_feed_timestamp(parsed.feed);
        try self.rate_limit_remove(feed_id);
        try self.request_failed_remove(feed_id);
        try self.updateFeedUpdate(feed_id, feed_update_input, parsed.item_interval);

        if (parsed.items.len == 0) {
            return;
        }

        try self.updateAndRemoveFeedItems(parsed.items);
    }

    pub fn rate_limit_remove(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        try self.sql_db.raw("DELETE FROM rate_limit WHERE feed_id = ?", .{feed_id}).exec();
    }

    pub fn rate_limit_add(self: *Self, feed_id: Feed.ID, utc_sec: i64) !void {
        std.debug.assert(feed_id != .unassigned);
        const query =
        \\INSERT INTO rate_limit 
        \\  (feed_id, next_utc_sec) VALUES (?1, ?2)
        \\ON CONFLICT(feed_id) DO UPDATE SET
        \\  next_utc_sec = ?2,
        \\  count = count + 1,
        \\  last_utc_sec = strftime('%s', 'now')
        ;
        
        try self.sql_db.raw(query, .{ feed_id, utc_sec}).exec();
    }

    pub fn request_failed_add(self: *Self, feed_id: Feed.ID, reason: []const u8) !void {
        std.debug.assert(feed_id != .unassigned);
        const query = "INSERT INTO feed_request_failed (feed_id, reason) VALUES (?, ?)";

        try self.sql_db.raw(query, .{feed_id, reason}).exec();
    }

    pub fn request_failed_remove(self: *Self, feed_id: Feed.ID) !void {
        try self.sql_db.raw("DELETE FROM feed_request_failed WHERE feed_id = ?", .{feed_id}).exec();
    }

    pub fn request_failed_ids(self: *Self, allocator: Allocator) ![]const Feed.ID {
        const query =
        \\select distinct(feed_id) from feed_request_failed
        ;

        var res = try std.array_list.Managed(Feed.ID).initCapacity(allocator, 10);
        errdefer res.deinit();

        const raw_query = self.sql_db.raw(query, .{});
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        while (try stmt.next(Feed.ID, allocator)) |row| {
            try res.append(row);
        }

        return res.toOwnedSlice();
    }

    const FeedFailedRequest = struct {
        utc_sec: i64,
        reason: []const u8,
    };

    pub fn request_failed_slice(self: *Self, allocator: Allocator, feed_id: Feed.ID) ![]const FeedFailedRequest {
        assert(feed_id != .unassigned);
        const capacity = 10;
        const query = std.fmt.comptimePrint(
        \\SELECT utc_sec, reason FROM feed_request_failed
        \\WHERE feed_id = ?
        \\ORDER BY utc_sec DESC
        \\LIMIT {d}
        , .{capacity});

        var res = try std.array_list.Managed(FeedFailedRequest).initCapacity(allocator, capacity);
        errdefer res.deinit();

        const raw_query = self.sql_db.raw(query, .{feed_id});
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        while (try stmt.next(FeedFailedRequest, allocator)) |row| {
            res.appendAssumeCapacity(row);
        }

        return res.toOwnedSlice();
    }

    pub fn insertFeed(self: *Self, feed: Feed) !Feed.ID {
        const query =
            \\INSERT INTO feed (title, feed_url, page_url, icon_id, updated_timestamp)
            \\VALUES (
            \\  ?1,
            \\  ?2,
            \\  ?3,
            \\  ?4,
            \\  ?5
            \\) ON CONFLICT(feed_url) DO NOTHING
            \\RETURNING feed_id;
        ;

        var buf: [2 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{f}", .{feed.feed_url});
        const feed_url = w.buffered();
        const page_url = blk: {
            if (feed.page_url) |page_url| {
                try w.print("{f}", .{page_url});
                break :blk w.buffered()[feed_url.len..];
            }
            break :blk null;
        };

        const raw_query = self.sql_db.raw(query, .{
             feed.title orelse "",
             feed_url,
             page_url,
             feed.icon_id,
             feed.updated_timestamp,
        });

        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        const feed_id = try stmt.next(Feed.ID, self.allocator) orelse return Error.FeedExists;

        return feed_id;
    }

    pub fn get_feed_id_with_url(self: *Self, url: []const u8) !?Feed.ID {
        const query =
            \\SELECT feed_id FROM feed WHERE feed_url = ? OR page_url = ?;
        ;
        return try self.sql_db.raw(query, .{ url, url }).get(Feed.ID);
    }
    
    pub fn getFeedsWithUrl(self: *Self, allocator: Allocator, url: []const u8) ![]const Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, icon_id, updated_timestamp FROM feed
        ;
        const raw_query = self.sql_db.raw(query, .{})
            .where("feed_url LIKE '%' || ? || '%' OR page_url LIKE '%' || ? || '%'", .{url, url});

        return try fetch_all_feeds(allocator, raw_query, 10);
    }

    pub fn getLatestFeedsWithUrl(self: *Self, allocator: Allocator, inputs: [][]const u8, opts: ShowOptions) ![]const Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, icon_id, updated_timestamp FROM feed
        ;
        var q = self.sql_db.raw(query, .{});

        if (inputs.len > 0) {
            const query_like = "feed_url LIKE '%' || ? || '%' OR page_url LIKE '%' || ? || '%'";
            for (inputs) |term| {
                q = q.where(query_like, .{term, term});
            }
        }

        q = q.orderBy("updated_timestamp DESC");
        q = q.limit(opts.limit);

        return try fetch_all_feeds(allocator, q, @intCast(opts.limit));
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
        return try self.sql_db.raw(query, .{url, url}).get(bool) orelse false;
    }

    pub fn getFeedsToUpdate(self: *Self, allocator: Allocator, search_term: ?[]const u8, options: UpdateOptions) ![]const FeedToUpdate {
        // TODO: rethink this query.
        // - Do I need the 'item' table stuff?
        // - Do subquery instead?
        // Had problem with query because there were no results but a row with
        // all NULL values was returned. This was caused by max() fn and
        // no 'group by'. 
        const query =
        \\select 
        \\  feed.feed_id,
        \\  feed.feed_url,
        \\  feed_update.etag_or_last_modified,
        \\  item.id as latest_item_id,
        \\  item.link as latest_item_link,
        \\  item.updated_timestamp as latest_updated_timestamp
        \\from feed
        \\LEFT JOIN feed_update ON feed.feed_id = feed_update.feed_id
        \\LEFT JOIN item ON feed.feed_id = item.feed_id and item.position = 0
        \\
        ;

        storage_arr.shrinkRetainingCapacity(0);
        storage_arr.appendSliceAssumeCapacity(query);

        var has_where = false;

        if (!options.force) {
            has_where = true;
            const failed_request_query = select_request_failed ++
            \\where feed_request_failed.feed_id = feed.feed_id
            ;
            storage_arr.appendSliceAssumeCapacity(comptimePrint(
                \\WHERE ifnull(
                \\  (select unixepoch() >= min(result) from
                \\    (select {s} as result from rate_limit where rate_limit.feed_id = feed.feed_id
                \\     union
                \\     {s} 
                \\    )
                \\  ),
                \\  (unixepoch() >= last_update + item_interval)
                \\)
            , .{rate_limit_iif_utc_sec, failed_request_query}));
        }

        const query_opts = blk: {
            if (search_term) |term| {
                if (term.len > 0) {
                    const cond_start = if (has_where) " AND " else " WHERE ";
                    storage_arr.appendSliceAssumeCapacity(cond_start);
                    storage_arr.appendSliceAssumeCapacity("(feed.feed_url LIKE '%' || ? || '%' OR feed.page_url LIKE '%' || ? || '%' OR feed.title LIKE '%' || ? || '%')");
                    break :blk .{term, term, term};
                }
            }
            break :blk null;
        };

        storage_arr.appendSliceAssumeCapacity(" GROUP BY item.feed_id");

        const raw_query = if (query_opts) |opts| self.sql_db.raw(storage_arr.items, opts)
            else self.sql_db.raw(storage_arr.items, .{});

        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        var res = try std.array_list.Managed(FeedToUpdate).initCapacity(allocator, 10);
        errdefer res.deinit();

        while (try stmt.next(FeedToUpdate.Raw, allocator)) |row| {
            var new = row;
            new.feed_url = try allocator.dupe(u8, row.feed_url);
            try res.append(try FeedToUpdate.from_raw(new));
        }

        return try res.toOwnedSlice();
    }

    pub fn deleteFeed(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        try self.sql_db.query(Feed).where("feed_id", feed_id).delete().exec();
    }

    pub fn update_feed_timestamp(self: *Self, feed: Feed) !void {
        const query =
            \\UPDATE feed SET updated_timestamp = ?1
            \\WHERE feed_id = ?2;
        ;
        try self.sql_db.raw(query, .{ feed.updated_timestamp, feed.feed_id }).exec();
    }

    pub const FeedFields = struct {
        feed_id: Feed.ID,
        title: []const u8,
        page_url: []const u8,
        icon_id: types.IconRender.ID = .unassigned,
        tags: [][]const u8,
    };

    pub fn update_feed_fields(self: *Self, allocator: Allocator, fields: FeedFields) !void {
        // Remove tags that aren't part of .tags 
        var buf: [1024]u8 = undefined;
        var buf_cstr: [256]u8 = undefined;

        if (fields.tags.len > 0) {
            var tags_str: std.ArrayList(u8) = .empty;
            defer tags_str.deinit(allocator);

            {
                const tag_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{fields.tags[0]});
                const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                const tag_slice = mem.sliceTo(c_str, 0x0);
                try tags_str.appendSlice(allocator, tag_slice);
            }

            for (fields.tags[1..]) |tag| {
                const tag_cstr = try std.fmt.bufPrintZ(&buf_cstr, "{s}", .{tag});
                const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                const tag_slice = mem.sliceTo(c_str, 0);
                try tags_str.append(allocator, ',');
                try tags_str.appendSlice(allocator, tag_slice);
            }

            const query_fmt = "DELETE FROM feed_tag WHERE feed_id = ? and tag_id not in (select tag_id from tag where name in (?))";
            try self.sql_db.raw(query_fmt, .{ fields.feed_id, tags_str.items }).exec();
        } else {
            const query = "DELETE FROM feed_tag WHERE feed_id = ?";
            try self.sql_db.raw(query, .{fields.feed_id}).exec();
        }

        // Make sure all tags exist
        try self.tags_add(fields.tags);
        for (fields.tags) |tag| {
            const query = 
            \\insert into feed_tag (feed_id, tag_id) values 
            \\  (?, (select tag_id from tag where name = ? limit 1)) ON CONFLICT DO NOTHING
            ;
            try self.sql_db.raw(query, .{
                fields.feed_id,
                tag,
            }).exec();
        }

        // Update feed_title and page_url
        const query = 
        \\UPDATE feed 
        \\SET title = ?, page_url = ?, icon_id = ?
        \\WHERE feed_id = ?
        ;

        try self.sql_db.raw(query, .{
            fields.title,
            fields.page_url,
            fields.icon_id,
            fields.feed_id,
        }).exec();
    }

    pub fn hasFeedWithId(self: *Self, feed_id: Feed.ID) !bool {
        assert(feed_id != .unassigned);
        const query = "SELECT EXISTS(SELECT 1 FROM feed WHERE feed_id = ?)";
        return (try self.sql_db.raw(query, .{feed_id}).get(bool)).?;
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
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\RETURNING item_id;
        ;

        var buf_link: [1024]u8 = undefined;
        const len = @min(inserts.len, app_config.max_items);
        for (inserts[0..len], 0..) |*item, i| {
            const link = blk: {
                if (item.link) |link| {
                    break :blk try std.fmt.bufPrint(&buf_link, "{f}", .{link});
                }
                break :blk null;
            };
            const item_id = try self.sql_db.raw(query, .{
                item.feed_id,
                item.title,
                link,
                item.id,
                item.updated_timestamp,
                i,
            }).get(FeedItem.ID) ;
            item.item_id = item_id orelse .unassigned;
        }
        return inserts;
    }

    pub fn getLatestFeedItemsWithFeedId(self: *Self, feed_id: Feed.ID, opts: ShowOptions) ![]const FeedItem {
        assert(feed_id != .unassigned);
        return try self.sql_db.raw("select feed_id, item_id, title, id, link, updated_timestamp from item", .{})
            .where("feed_id = ?", feed_id)
            .orderBy("position ASC")
            .limit(opts.@"item-limit")
            .fetchAll(FeedItem);
    }

    pub fn updateFeedUpdate(self: *Self, feed_id: Feed.ID, feed_update: FeedUpdate, item_interval: i64) !void {
        assert(feed_id != .unassigned);
        const query =
            \\INSERT INTO feed_update 
            \\  (feed_id, update_interval, etag_or_last_modified, item_interval)
            \\VALUES 
            \\  (?1, ?2, ?3, ?4)
            \\ ON CONFLICT(feed_id) DO UPDATE SET
            \\  update_interval = ?2,
            \\  etag_or_last_modified = ?3,
            \\  item_interval = ?4,
            \\  last_update = strftime('%s', 'now')
            \\;
        ;
        try self.sql_db.raw(query, .{
            feed_id,
            feed_update.update_interval,
            feed_update.etag_or_last_modified,
            item_interval,
        }).exec();
    }

    pub fn icons_remove_unused(self: *Self) !void {
        const query =
            \\delete from icon
            \\where icon_id not in
            \\  (select distinct(icon_id) from feed where icon_id not null);
        ;
        try self.sql_db.raw(query, .{}).exec();
    }

    pub fn icon_upsert(self: *Self, icon: types.Icon) !Icon.ID {
        assert(icon.data.len > 0);
        assert(icon.etag_or_last_modified_or_hash.len > 0);

        const query =
            \\INSERT INTO icon 
            \\  (icon_url, icon_data, etag_or_last_modified_or_hash)
            \\VALUES 
            \\  (?1, ?2, ?3)
            \\ON CONFLICT DO UPDATE SET
            \\  icon_data = ?2,
            \\  etag_or_last_modified_or_hash = ?3
            \\ WHERE
            \\  etag_or_last_modified_or_hash != ?3
            \\RETURNING icon_id;
        ;

        var buf: [1024]u8 = undefined;
        const icon_url = try std.fmt.bufPrint(&buf, "{f}", .{icon.url});

        const data_blob: sql.Value = .{ .blob = icon.data };
        const icon_id_opt = try self.sql_db.raw(query, .{
            icon_url,
            data_blob,
            icon.etag_or_last_modified_or_hash,
        }).get(u64) orelse try self.sql_db.raw("select icon_id from icon where icon_url = ?", .{
            icon_url,
        }).get(u64);

        if (icon_id_opt) |icon_id| {
            return @enumFromInt(icon_id);
        }

        return .unassigned;
    }

    pub fn updateLastUpdate(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        const query = "update feed_update set last_update = strftime('%s', 'now') where feed_id = ?;";
        try self.sql_db.raw(query, .{feed_id}).exec();
    }

    pub fn updateAndRemoveFeedItems(self: *Self, items: []const FeedItem) !void {
        assert(items.len > 0);
        const feed_id = items[0].feed_id;
        {
            const query = "update item set position = position + ? where feed_id = ?;";
            try self.sql_db.raw(query, .{ items.len, feed_id }).exec();
        }
        try self.upsertFeedItems(items);
        try self.cleanFeedItems(feed_id);
    }

    // Initial item table state
    // 1 | Title 1 | 2
    // 2 | Title 2 | 1
    // Update item table
    // ...
    // 3 | Title 3 | 4
    // 4 | Title 4 | 3
    pub fn upsertFeedItems(self: *Self, inserts: []const FeedItem) !void {
        assert(inserts.len > 0);

        const query_with_id =
            \\INSERT INTO item (feed_id, title, link, id, updated_timestamp, position)
            \\VALUES (?, ?, ?, ?, ?, ?)
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
            \\INSERT INTO item (feed_id, title, updated_timestamp, position)
            \\VALUES (?, ?, ?, ?)
            \\;
        ;

        var buf_link: [1024]u8 = undefined;
        
        for (inserts, 0..) |item, i| {
            if (item.id != null or item.link != null) {
                const link = if (item.link) |link|
                    try std.fmt.bufPrint(&buf_link, "{f}", .{link})
                else null;
                try self.sql_db.raw(query_with_id, .{
                    item.feed_id,
                    item.title,
                    link,
                    item.id,
                    item.updated_timestamp,
                    i,
                }).exec();
            } else {
                try self.sql_db.raw(query_without_id, .{
                    item.feed_id,
                    item.title,
                    item.updated_timestamp,
                    i,
                }).exec();
            }
        }
    }

    pub fn cleanFeedItems(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        const del_query =
            \\DELETE FROM item WHERE feed_id = ? and position >= ?
        ;
        try self.sql_db.raw(del_query, .{ feed_id, self.options.max_item_count }).exec();
    }

    pub fn feed_items_with_feed_id(self: *Self, allocator: Allocator, feed_id: Feed.ID) ![]const FeedItemRender {
        const query =
            \\select feed_id, title, link, updated_timestamp, created_timestamp
            \\from item where feed_id = ? order by updated_timestamp DESC, position ASC
        ;

        return try self.fetch_feed_item_render(allocator, query, .{feed_id}, .{});
    }

    const FeedItemRenderOptions = struct {
        capacity: usize = app_config.max_items,
    };

    fn fetch_feed_item_render(self: *@This(), allocator: Allocator, query: []const u8, args: anytype, opts: FeedItemRenderOptions,) ![]const FeedItemRender {
        const raw_query = self.sql_db.raw(query, args);
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        var res = try std.array_list.Managed(FeedItemRender).initCapacity(allocator, opts.capacity);
        errdefer res.deinit();

        while (try stmt.next(FeedItemRender.DB, allocator)) |row| {
            const link_len = if (row.link) |v| v.len else 0;
            const len = row.title.len + link_len;
            var buf = try allocator.alloc(u8, len);

            const title = buf[0..row.title.len];
            mem.copyForwards(u8, title, row.title);

            const link = blk: {
                if (row.link) |val| {
                    const result = buf[row.title.len..];
                    mem.copyForwards(u8, result, val);
                    break :blk result;
                }
                break :blk null;
            };

            var new = row;
            new.title = title;
            new.link = link;
            res.appendAssumeCapacity(try .from_raw(new));
        }

        return res.toOwnedSlice();
    }

    pub fn tags_all(self: *Self, allocator: Allocator) ![]const []const u8 {
        const query = "SELECT name FROM tag ORDER BY name ASC;";
        const raw_query = self.sql_db.raw(query, .{});

        return try all([]const u8, allocator, raw_query);
    }

    pub fn tag_with_id(self: *Self, allocator: Allocator, tag_id: types.SqliteId) !?TagResult {
        const query = "SELECT tag_id, name FROM tag where tag_id = ?;";
        const raw_query = self.sql_db.raw(query, .{tag_id});

        return try one(TagResult, allocator, raw_query);
    }

    pub fn tag_update(self: *Self, data: TagResult) !void {
        const query =
            \\UPDATE tag SET
            \\  name = ?1
            \\WHERE tag_id = ?2
        ;
        try self.sql_db.raw(query, .{data.name, data.tag_id}).exec();
    }
        
    const TagResult = struct{tag_id: types.SqliteId, name: []const u8};
    pub fn tags_all_with_ids(self: *Self, allocator: Allocator) ![]const TagResult {
        const query = "select * from tag order by name ASC;";
        const raw_query = self.sql_db.raw(query, .{});

        return all(TagResult, allocator, raw_query);
    }

    pub fn tags_remove_with_id(self: *Self, tag_id: types.SqliteId) !void {
        const query =
        \\delete from tag where tag_id = ?
        ;
        try self.sql_db.raw(query, .{tag_id}).exec();
    }

    pub fn feed_tags(self: *Self, allocator: Allocator, feed_id: Feed.ID) ![]const []const u8 {
        assert(feed_id != .unassigned);
        const query = 
        \\select name from tag where tag_id in (
        \\  select distinct(tag_id) from feed_tag where feed_id = ?
        \\)
        ;
        const raw_query = self.sql_db.raw(query, .{feed_id});
        return try all([]const u8, allocator, raw_query);
    }
        
    pub fn tags_add(self: *Self, tags: [][]const u8) !void {
        const query = "INSERT INTO tag (name) VALUES(?) ON CONFLICT DO NOTHING;";
        for (tags) |tag| {
            assert(tags.len > 0);
            try self.sql_db.raw(query, .{tag}).exec();
        }
    }

    pub fn tags_ids(self: *Self, tags: [][]const u8, buf: []types.SqliteId) ![]types.SqliteId {
        const query = "select tag_id from tag where name = ?;"; 
        var i: usize = 0;
        for (tags) |tag| {
            const raw_query = self.sql_db.raw(query, .{tag});
            if (try one(types.SqliteId, undefined, raw_query) ) |value| {
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
            try self.sql_db.raw(query, .{tag}).exec();
        }
    }

    pub fn tags_feed_add(self: *Self, feed_id: Feed.ID, tag_ids: []types.SqliteId) !void {
        assert(feed_id != .unassigned);
        const query = "INSERT INTO feed_tag (feed_id, tag_id) VALUES (?, ?) ON CONFLICT DO NOTHING";
        for (tag_ids) |tag_id| {
            try self.sql_db.raw(query, .{feed_id, tag_id}).exec();
        }
    }

    pub fn tags_feed_remove(self: *Self, feed_id: Feed.ID, tags: [][]const u8) !void {
        assert(feed_id != .unassigned);
        const query = "DELETE FROM feed_tag WHERE feed_id = ? AND tag_id = (select tag_id from tag where name = ?)";
        for (tags) |tag| {
            try self.sql_db.raw(query, .{feed_id, tag}).exec();
        }
    }

    pub const After = Feed.ID;
    pub const Before = Feed.ID;
    const FeedSearchArgs = struct {
        tags: [][]const u8 = &.{},
        search: ?[]const u8 = null,
        after: After = .unassigned,
        before: Before = .unassigned,
        has_untagged: bool = false,
    };

    fn search_query_where(self: *Self, allocator: Allocator, args: FeedSearchArgs) ![]const u8 {
        assert(
            (args.before == .unassigned and args.after == .unassigned) or
            (args.before != .unassigned and args.after == .unassigned) or
            (args.before == .unassigned and args.after != .unassigned)
        );

        var buf: [1024]u8 = undefined;
        var buf_cstr: [256]u8 = undefined;
        var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
        errdefer aw.deinit();
        var where_writer = &aw.writer;

        var has_prev_cond = false;

        if (args.before != .unassigned) {
            const after_fmt =
            \\((updated_timestamp > (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
            \\      OR updated_timestamp > (select updated_timestamp from feed where feed_id = {[id]d}))
            ;

            try where_writer.writeAll("WHERE ");
            try where_writer.print(after_fmt, .{.id = @intFromEnum(args.before) });
            has_prev_cond = true;
        } else {
            if (args.after != .unassigned) {
                const after_fmt =
                \\((updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
                \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}))
                ;

                try where_writer.writeAll("WHERE ");
                try where_writer.print(after_fmt, .{.id = @intFromEnum(args.after) });
                has_prev_cond = true;
            }
        }
        
        const ids_tag = blk: {
            if (args.tags.len > 0) {
                var tags_str: std.ArrayList(u8) = try .initCapacity(allocator, 64);
                defer tags_str.deinit(allocator);

                {
                    try tags_str.appendSlice(allocator, args.tags[0]);
                }

                for (args.tags[1..]) |tag| {
                    try tags_str.appendSlice(allocator, ",");
                    try tags_str.appendSlice(allocator, tag);
                }

                const query = "SELECT tag_id FROM tag where name in (?)";

                break :blk try self.sql_db.raw(query, .{tags_str.items}).fetchAll(u64);
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
        
        return aw.writer.buffered();
    }

    pub fn feeds_search_complex(self: *Self, allocator: Allocator, args: FeedSearchArgs) ![]const Feed {
        assert(
            (args.before == .unassigned and args.after == .unassigned) or
            (args.before != .unassigned and args.after == .unassigned) or
            (args.before == .unassigned and args.after != .unassigned)
        );

        const query_where = try self.search_query_where(allocator, args);
        defer allocator.free(query_where);
        const query_fmt = 
        \\SELECT feed_id, title, feed_url, page_url, icon_id, updated_timestamp FROM feed {s}
        \\ORDER BY updated_timestamp DESC, feed_id DESC LIMIT
        ++ comptimePrint(" {d}", .{app_config.query_feed_limit})
        ;
        const query = try std.fmt.allocPrint(allocator, query_fmt, .{query_where});
        defer allocator.free(query);

        const raw_query = self.sql_db.raw(query, .{});
        return try fetch_all_feeds(allocator, raw_query, app_config.query_feed_limit);
    }

    pub fn feeds_search_has_previous(self: *Self, allocator: Allocator, args: FeedSearchArgs) !bool {
        assert(args.before != .unassigned);

        const query_where = try self.search_query_where(allocator, args);
        defer allocator.free(query_where);
        const query_fmt = 
        \\SELECT 1 FROM feed {s}
        \\ORDER BY updated_timestamp DESC, feed_id DESC LIMIT 1
        ;
        const query = try std.fmt.allocPrint(allocator, query_fmt, .{query_where});
        defer allocator.free(query);
        const result = try self.sql_db.raw(query, .{}).get(bool);
        return result orelse false;
    }
    
    const after_cond_raw =
    \\AND ((updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
    \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d})) 
    ;

    pub fn feed_with_id(self: *Self, allocator: Allocator, feed_id: Feed.ID) !?Feed {
        const query = 
        \\SELECT feed_id, title, feed_url, page_url, icon_id, updated_timestamp FROM feed
        \\WHERE feed_id = ?1
        ;

        const raw_query = self.sql_db.raw(query, .{feed_id});
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        const feed_db = try stmt.next(Feed.DB, allocator) orelse return null;

        const page_url_len = if (feed_db.page_url) |v| v.len else 0;
        const title_len = if (feed_db.title) |v| v.len else 0;
        const len = feed_db.feed_url.len + page_url_len + title_len;

        var strings = try std.array_list.Managed(u8).initCapacity(allocator, len);
        errdefer strings.deinit();

        var new = feed_db;

        {
            const start = strings.items.len;
            strings.appendSliceAssumeCapacity(feed_db.feed_url);
            new.feed_url = strings.items[start..];
        }

        if (feed_db.page_url) |page_url| {
            const start = strings.items.len;
            strings.appendSliceAssumeCapacity(page_url);
            new.page_url = strings.items[start..];
        }

        if (feed_db.title) |title| {
            const start = strings.items.len;
            strings.appendSliceAssumeCapacity(title);
            new.title = strings.items[start..];
        }

        return try .from_raw(new);
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
        \\INSERT INTO add_rule_host(name) VALUES (?)
        \\ON CONFLICT (name) DO UPDATE SET name = excluded.name
        \\RETURNING host_id;
        ;

        const match_host_id = try self.sql_db.raw(query_insert_host, .{rule.match_host}).get(u64)
            orelse return error.AddRuleNoMatchHostId;

        const result_host_id = blk: {
            if (!mem.eql(u8, rule.match_host, rule.result_host)) {
                break :blk try self.sql_db.raw(query_insert_host, .{rule.result_host}).get(u64)
                    orelse return error.AddRuleNoResultHostId;
            }
            break :blk match_host_id;
        };

        const query_insert_rule = 
        \\insert or ignore into 
        \\  add_rule(match_host_id, match_path, result_host_id, result_path) 
        \\  values (?, ?, ?, ?);
        ;
        try self.sql_db.raw(query_insert_rule, .{match_host_id, rule.match_path, result_host_id, rule.result_path}).exec();
    }

    const RuleMatchStr = struct {
        match_url: []const u8,
        result_url: []const u8,
    };
    pub fn rules_all(self: *Self, allocator: Allocator) ![]const RuleMatchStr {
        const query_fmt = 
        \\select 
        \\(select name from add_rule_host where host_id = add_rule.match_host_id 
        \\) || match_path as match_url,
        \\(select name from add_rule_host where host_id = add_rule.result_host_id 
        \\) || result_path as result_url
        \\from add_rule
        ;
        const raw_query = self.sql_db.raw(query_fmt, .{});
        return try all(RuleMatchStr, allocator, raw_query);
    }

    const RuleFilterMatch = struct {
        add_rule_id: usize,
        match_url: []const u8,
        result_url: []const u8,
    };
    pub fn rules_filter(self: *Self, allocator: Allocator, filter: []const u8) ![]const RuleFilterMatch {
        const query_fmt = 
        \\select 
        \\add_rule_id,
        \\(select name from add_rule_host where host_id = add_rule.match_host_id 
        \\) || match_path as match_url,
        \\(select name from add_rule_host where host_id = add_rule.result_host_id 
        \\) || result_path as result_url
        \\from add_rule 
        \\where 
        \\  add_rule_id in (select add_rule_id from add_rule_host where name like '%' || ?1 || '%') or
        \\  match_path like '%' || ?1 || '%' or
        \\  result_path like '%' || ?1 || '%'
        ;
        const raw_query = self.sql_db.raw(query_fmt, .{ filter });
        return try all(RuleFilterMatch, allocator, raw_query);
    }
    
    pub fn rule_remove(self: *Self, add_rule_id: usize) !void {
        try self.sql_db.raw("DELETE FROM add_rule WHERE add_rule_id = ?", .{add_rule_id}).exec();
    }


    pub fn has_rule(self: *Self, rule: Rule) !bool {
        const query =
            \\select 1 from add_rule where
            \\match_path = ?1 AND result_path = ?2
            \\AND (select host_id from add_rule_host where name = ?3)
            \\AND (select host_id from add_rule_host where name = ?4)
        ;
        return try self.sql_db.raw(query, .{
            rule.match_path, rule.result_path,
            rule.match_host, rule.result_host,
        }).get(bool) orelse false;
    }

    const AddRule = @import("add_rule.zig");
    pub fn get_rules_for_host(self: *Self, allocator: Allocator, host: []const u8) ![]const AddRule.RuleWithHost {
        const query_select_host = "SELECT host_id FROM add_rule_host WHERE name = ?";
        const host_id = try self.sql_db.raw(query_select_host, .{host}).get(u64)  orelse return &.{};
        const query = 
        \\select 
        \\  match_path,
        \\  (select name from add_rule_host where host_id = add_rule.result_host_id) as result_host, 
        \\  result_path
        \\from add_rule 
        \\where match_host_id = ?;
        ;

        const raw_query = self.sql_db.raw(query, .{host_id});
        return try all(AddRule.RuleWithHost, allocator, raw_query);
    }

    pub fn get_add_rule(self: *Self, allocator: Allocator, uri: std.Uri) !?Rule {
        const uri_host = uri.host orelse return null;
        var buf: [1024]u8 = undefined;
        const uri_host_raw = try uri_host.toRaw(&buf);
        const query_select_host = "SELECT host_id FROM add_rule_host WHERE name = ?";
        const host_id = try self.sql_db.raw(query_select_host, .{uri_host_raw}).get(u64) orelse return null;

        const query = 
        \\select 
        \\  (select name from add_rule_host where host_id = ?1) as match_host,
        \\  match_path, 
        \\  (select name from add_rule_host where host_id = ?1) as result_host,
        \\  result_path 
        \\from add_rule 
        \\where match_host_id = ?1 AND match_path like ?2;
        ;

        const uri_path_raw = try uri.path.toRaw(&buf) ;
        mem.replaceScalar(u8, @constCast(uri_path_raw), '*', '%');
        const raw_query = self.sql_db.raw(query, .{ host_id, uri_path_raw });
        return try one(Rule, allocator, raw_query);
    }

    // 259200 - 3 days in seconds
    const rate_limit_iif_utc_sec =
    \\cast(iif(count < 3, next_utc_sec, 
    \\  max(next_utc_sec,
    \\    last_utc_sec + min(3600 * (count * count), 259200)
    \\  )
    \\) as INTEGER)
    ;

    // TODO: add special value for else branch that show that count exceeds or is 7
    // Or return also count(*) and let code handle it?
    // This was caused by problem when datetime library could not handle
    // max_int value.
    const select_request_failed =
    \\select iif(count(*) < 7
    \\    , max(utc_sec) + min(3600 * (count(*) * count(*)), 259200)
    \\    , 9223372036854775807
    \\  ) as result
    \\  from feed_request_failed
    \\
    ;

    const failed_request_utc_sec = comptimePrint(
    \\select min(result) from (
    \\  {s}
    \\  group by feed_id
    \\)
    , .{select_request_failed})
    ;

    pub fn next_update_timestamp(self: *Self) !?i64 {
        const query = comptimePrint(
        \\select min(val) from (
        \\  select last_update + item_interval as val from feed_update
        \\    where feed_id not in (
        \\      select feed_id from rate_limit 
        \\      UNION
        \\      select feed_id from feed_request_failed
        \\    )
        \\  UNION
        \\  select {s} from rate_limit
        \\  UNION
        \\  {s}
        \\)
        , .{rate_limit_iif_utc_sec, failed_request_utc_sec})
        ;
        return try self.sql_db.raw(query, .{}).get(i64);
    }

    // NOTE: null means that there have been to many failed feed requests in a row
    pub fn next_update_feed(self: *Self, feed_id: Feed.ID) !?i64 {
        assert(feed_id != .unassigned);
        const query =
            \\select case
            \\  when count(*) >= 7 then null
            \\  when count(*) > 0 then max(utc_sec) + min(3600 * (count(*) * count(*)), 259200)
            \\  else ifnull((select case
            \\           when count >= 3 then max(next_utc_sec, last_utc_sec + min(3600 * (count * count), 259200))
            \\           when count > 0 then next_utc_sec
            \\         end
            \\         from rate_limit where feed_id = ?1)
            \\         , (select last_update + item_interval from feed_update where feed_id = ?1)
            \\       )
            \\end
            \\from feed_request_failed
            \\where feed_id = ?1
        ;
        const result = try self.sql_db.raw(query, .{feed_id}).get(i64);
        if (result) |val| if (val != 0) {
            return val;
        };
        return null;
    }

    pub fn feed_last_update(self: *Self, feed_id: Feed.ID) !?i64 {
        assert(feed_id != .unassigned);
        return try self.sql_db.raw("select last_update from feed_update where feed_id = ?", .{@intFromEnum(feed_id)}).get(i64);
    }

    pub fn get_items_latest_added(self: *Self, allocator: Allocator) ![]const FeedItemRender {
        const limit = 100;
        const query = std.fmt.comptimePrint(
        \\SELECT feed_id, title, link, updated_timestamp, created_timestamp
        \\FROM item WHERE created_timestamp > strftime("%s", "now", "-3 days") ORDER BY created_timestamp DESC
        \\LIMIT {d}
        , .{limit})
        ;

        return try self.fetch_feed_item_render(allocator, query, .{}, .{.capacity = limit});
    }

    pub fn get_latest_change(self: *Self) !?i64 {
        const query = 
            \\select max(
            \\  (SELECT max(created_timestamp) FROM item),
            \\  (SELECT max(last_update) FROM feed_update),
            \\  (SELECT max(last_update_timestamp) FROM table_last_update where table_name = 'feed' or table_name = 'tag')
            \\);
        ;
        return try self.sql_db.raw(query, .{}).get(i64);
    }

    pub fn get_latest_feed_change(self: *Self, feed_id: Feed.ID) !?i64 {
        assert(feed_id != .unassigned);
        const query = 
            \\select max(
            \\  (SELECT max(created_timestamp) FROM item WHERE feed_id = ?),
            \\  (SELECT max(last_update) FROM feed_update),
            \\  (SELECT max(last_update_timestamp) FROM table_last_update where table_name = 'feed' or table_name = 'tag')
            \\);
        ;
        return try self.sql_db.raw(query, .{@intFromEnum(feed_id)}).get(i64) ;
    }

    pub fn get_tags_change(self: *Self) !?i64 {
        const query = 
            \\SELECT last_update_timestamp FROM table_last_update where table_name = 'tag';
        ;
        return try self.sql_db.raw(query, .{}).get(i64);
    }

    pub fn get_feeds_with_ids(self: *Self, allocator: Allocator, ids: []const Feed.ID) ![]const Feed {
        std.debug.assert(ids.len > 0);
        var query_al = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer query_al.deinit(allocator);
        query_al.appendSliceAssumeCapacity(
            \\select feed_id, title, feed_url, page_url, icon_id, updated_timestamp from feed where feed_id in (
        );
        // u64 numbers max length
        var buf: [20]u8 = undefined;
        var id_str = try std.fmt.bufPrint(&buf, "{d}", .{ids[0]});
        try query_al.appendSlice(allocator, id_str);
        for (ids[1..]) |id| {
            id_str = try std.fmt.bufPrint(&buf, ",{d}", .{id});
            try query_al.appendSlice(allocator, id_str);
        }
        try query_al.append(allocator, ')');

        const raw_query = self.sql_db.raw(query_al.items, .{});
        return try fetch_all_feeds(allocator, raw_query, ids.len);
    }

    fn fetch_all_feeds(allocator: Allocator, raw_query: sql.RawQuery, capacity: usize) ![]const Feed {
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        var res = try std.array_list.Managed(Feed).initCapacity(allocator, capacity);
        errdefer res.deinit();

        while (try stmt.next(Feed.DB, allocator)) |row| {
            const buf = try allocator.alloc(u8, row.strings_len());
            var w: std.Io.Writer = .fixed(buf);

            var new = row;
            w.writeAll(row.feed_url) catch unreachable;
            new.feed_url = w.buffered();

            if (row.page_url) |page_url| {
                const start = w.buffered().len;
                w.writeAll(page_url) catch unreachable;
                new.page_url = w.buffered()[start..];
            }

            if (row.title) |title| {
                const start = w.buffered().len;
                w.writeAll(title) catch unreachable;
                new.title = w.buffered()[start..];
            }

            try res.append(try Feed.from_raw(new));
        }

        return try res.toOwnedSlice();
    }

    pub fn icon_all(self: *Self, allocator: Allocator) ![]const Icon {
        const query =
        \\SELECT icon_id, icon_url, icon_data, etag_or_last_modified_or_hash
        \\FROM icon
        ;

        var res = std.array_list.Managed(Icon).init(allocator);
        errdefer res.deinit();

        const raw_query = self.sql_db.raw(query, .{});
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        while (try stmt.next(Icon.DB, allocator)) |row| {
            const len = row.icon_data.bytes.len;
            const icon_data: []u8 = try allocator.alloc(u8, len);
            errdefer allocator.free(icon_data);

            try res.append(try icon_from_icon_db(icon_data, row));
        }

        return res.toOwnedSlice();
    }

    pub fn feed_id_by_icon_id(self: *Self, icon_id: Icon.ID) !?Feed.ID {
        const query =
            \\SELECT feed_id FROM feed WHERE icon_id = ?
        ;
        const feed_id = try self.sql_db.raw(query, .{icon_id}).get(Feed.ID);
        return feed_id;
    }

    const IconMissing = struct {
        feed_id: Feed.ID,
        page_url: std.Uri,

        pub const Raw = struct {
            feed_id: usize,
            page_url: []const u8,
        };

        pub fn from_raw(raw: Raw) !IconMissing {
            return .{
                .feed_id = @enumFromInt(raw.feed_id),
                .page_url = try std.Uri.parse(raw.page_url),
            };
        }
    };

    pub fn feed_icons_missing(self: *Self, allocator: Allocator) ![]const IconMissing {
        const query =
        \\SELECT feed_id, page_url 
        \\FROM feed WHERE icon_id IS NULL AND page_url IS NOT NULL
        \\AND feed.feed_id NOT IN (select feed_id from icon_failed);
        ;

        var res = try std.array_list.Managed(IconMissing).initCapacity(allocator, 10);
        errdefer res.deinit();

        const raw_query = self.sql_db.raw(query, .{});
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        while (try stmt.next(IconMissing.Raw, allocator)) |raw| {
            try res.append(try .from_raw(raw));
        }

        return res.toOwnedSlice();
    }

    pub const IconFailed = struct {
        feed_id: Feed.ID,
        page_url: std.Uri,
        etag_or_last_modified_or_hash: []const u8,

        pub const Raw = struct {
            feed_id: u64,
            page_url: []const u8,
            etag_or_last_modified_or_hash: []const u8,
        };

        pub fn from_raw(raw: Raw) !IconFailed {
            return .{
                .feed_id = @enumFromInt(raw.feed_id),
                .page_url = try std.Uri.parse(raw.page_url),
                .etag_or_last_modified_or_hash = raw.etag_or_last_modified_or_hash,
            };
        }
    };

    // Failed icon request might icon status in DB:
    // 1) Failed on first try. Which means there is no icon in DB.
    // 2) Failed on any other try expect first. Which means there is an icon in DB.
    pub fn feed_icons_failed(self: *Self, allocator: Allocator) ![]const IconFailed {
        const query =
        \\SELECT feed.feed_id, feed.page_url,
        \\  (SELECT icon.etag_or_last_modified_or_hash FROM icon WHERE icon.icon_id = feed.icon_id) AS etag_or_last_modified_or_hash
        \\FROM icon_failed
        \\JOIN feed ON icon_failed.feed_id = feed.feed_id
        \\AND feed.page_url IS NOT NULL AND feed.icon_id IS NOT NULL
        ;

        var res = try std.array_list.Managed(IconFailed).initCapacity(allocator, 10);
        errdefer res.deinit();

        const raw_query = self.sql_db.raw(query, .{});
        var stmt = try raw_query.prepare();
        defer stmt.deinit();


        while (try stmt.next(IconFailed.Raw, allocator)) |raw| {
            try res.append(try .from_raw(raw));
        }

        return res.toOwnedSlice();
    }
    
    pub fn icon_update(self: *Self, curr_icon_uri: std.Uri, icon: types.Icon) !void {
        assert(icon.data.len > 0);

        var buf_curr: [1024]u8 = undefined;
        const curr_icon_url = try std.fmt.bufPrint(&buf_curr, "{f}", .{curr_icon_uri});

        var buf_icon: [1024]u8 = undefined;
        const icon_url = try std.fmt.bufPrint(&buf_icon, "{f}", .{icon.url});
        const data: sql.Blob = .{ .bytes = icon.data };
        if (mem.eql(u8, curr_icon_url, icon_url)) {
            const query = 
            \\UPDATE icon SET
            \\  icon_data = ?,
            \\  etag_or_last_modified_or_hash = ?
            \\WHERE icon_url = ?;
            ;
            const values = .{data, icon.etag_or_last_modified_or_hash, curr_icon_url};
            try self.sql_db.raw(query, values).exec();
        } else {
            const query = 
            \\UPDATE icon SET
            \\  icon_url = ?,
            \\  icon_data = ?,
            \\  etag_or_last_modified_or_hash = ?
            \\WHERE icon_url = ?;
            ;

            const values = .{icon_url, data, icon.etag_or_last_modified_or_hash, curr_icon_url};
            try self.sql_db.raw(query, values).exec();
        }
    }

    fn icon_from_icon_db(buf: []u8, icon_db: Icon.DB) !Icon {
        assert(buf.len >= icon_db.icon_data.bytes.len);
        // Need to allocate Blob.bytes
        mem.copyForwards(u8, buf, icon_db.icon_data.bytes);

        return .{
            .icon_id = icon_db.icon_id,
            .icon_url = try std.Uri.parse(icon_db.icon_url),
            .icon_data = buf,
            .etag_or_last_modified_or_hash = icon_db.etag_or_last_modified_or_hash,
        };
    }


    pub fn icon_by_id(self: *Self, allocator: Allocator, id: Icon.ID) !?Icon {
        const query =
        \\SELECT icon_id, icon_url, icon_data, etag_or_last_modified_or_hash
        \\FROM icon WHERE icon_id = ?;
        ;

        const raw_query = self.sql_db.raw(query, .{id});
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        const icon_db = try stmt.next(Icon.DB, allocator) orelse return null;

        const icon_data_buf: []u8 = try allocator.alloc(u8, icon_db.icon_data.bytes.len);
        errdefer allocator.free(icon_data_buf);

        return try icon_from_icon_db(icon_data_buf, icon_db);
    }
    
    pub fn icon_get_id(self: *Self, icon_url: []const u8) !Icon.ID {
        assert(is_url_or_data(icon_url));
        const query = 
        \\select icon_id FROM icon
        \\WHERE icon_url = ? or icon_data = ?
        \\LIMIT 1;
        ;
        const icon_id = try self.sql_db.raw(query, .{icon_url, icon_url}).get(Icon.ID) orelse return .unassigned;
        return icon_id;
    }

    pub fn feed_icon_update(self: *Self, feed_id: Feed.ID, icon_id: ?Icon.ID) !void {
        assert(feed_id != .unassigned);
        assert(icon_id != .unassigned);
        const query = 
        \\UPDATE feed SET
        \\  icon_id = ?
        \\WHERE feed_id = ?;
        ;

        try self.sql_db.raw(query, .{icon_id, feed_id}).exec();
    }

    pub const IconFailedInsert = struct {
        feed_id: Feed.ID,
        last_msg: ?[]const u8 = null,
    };

    pub fn icon_failed_add(self: *Self, icon_failed: IconFailedInsert) !void {
        const query =
        \\insert into icon_failed (feed_id, last_msg)
        \\values (?1, ?2)
        \\ON CONFLICT(feed_id) DO UPDATE SET
        \\  last_msg = ?2

        ;
        try self.sql_db.raw(query, .{
            icon_failed.feed_id,
            icon_failed.last_msg,
        }).exec();
    }

    pub fn icon_failed_remove(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        const query =
            \\DELETE FROM icon_failed WHERE feed_id = ?;
        ;
        try self.sql_db.raw(query, .{feed_id}).exec();
    }

    pub fn html_selector_add(self: *Self, feed_id: Feed.ID, options: parse.HtmlOptions) !void {
        assert(feed_id != .unassigned);
        const query =
            \\INSERT INTO html_selector (feed_id, container, link, heading, date, date_format)
            \\VALUES (
            \\  ?1,
            \\  ?2,
            \\  ?3,
            \\  ?4,
            \\  ?5,
            \\  ?6
            \\) ON CONFLICT(feed_id) DO UPDATE SET
            \\  container = ?2,
            \\  link = ?3,
            \\  heading = ?4,
            \\  date = ?5,
            \\  date_format = ?6
            \\;
        ;

        try self.sql_db.raw(query, .{
            feed_id,
            options.selector_container,
            options.selector_link,
            options.selector_heading,
            options.selector_date,
            options.date_format,
        }).exec();
    }

    pub fn html_selector_has(self: *Self, feed_id: Feed.ID) !bool {
        assert(feed_id != .unassigned);
        const query = "select 1 from html_selector where feed_id = ?";
        return try self.sql_db.raw(query, .{@intFromEnum(feed_id)}).get(bool) orelse false;
    }

    pub fn html_selector_get(self: *Self, allocator: Allocator, feed_id: Feed.ID) !?parse.HtmlOptions {
        assert(feed_id != .unassigned);
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

        const raw_query = self.sql_db.raw(query, .{feed_id});

        return one(parse.HtmlOptions, allocator, raw_query);
    }

    fn one(comptime T: type, allocator: Allocator, raw_query: sql.RawQuery) !?T {
        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        return stmt.next(T, allocator);
    }

    fn all(comptime T: type, allocator: Allocator, raw_query: sql.RawQuery) ![]const T {
        var res = try std.array_list.Managed(T).initCapacity(allocator, 10);
        errdefer res.deinit();

        var stmt = try raw_query.prepare();
        defer stmt.deinit();

        while (try stmt.next(T, allocator)) |row| {
            try res.append(row);
        }

        return res.toOwnedSlice();
    }
};

// TODO: feed.title default value should be null. Or use empty string ("") as default value?
const tables = &[_][]const u8{
    \\CREATE TABLE IF NOT EXISTS feed (
    \\  feed_id INTEGER PRIMARY KEY,
    \\  title TEXT NOT NULL,
    \\  feed_url TEXT NOT NULL UNIQUE,
    \\  page_url TEXT DEFAULT NULL,
    \\  icon_id INTEGER DEFAULT NULL REFERENCES icon (icon_id)
    \\    ON DELETE SET NULL
    \\    ON UPDATE CASCADE,
    \\  updated_timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS icon(
    \\  icon_id INTEGER PRIMARY KEY,
    \\  icon_url TEXT NOT NULL UNIQUE,
    \\  icon_data BLOB NOT NULL,
    \\  etag_or_last_modified_or_hash TEXT NOT NULL
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
        \\  etag_or_last_modified TEXT DEFAULT NULL,
        \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
        \\) STRICT;
    , .{ app_config.update_interval, types.seconds_in_10_days }),
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
    \\  UNIQUE(result_host_id, result_path, match_host_id, match_path)
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS rate_limit(
    \\  feed_id INTEGER UNIQUE NOT NULL,
    \\  next_utc_sec INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    \\  count INTEGER NOT NULL DEFAULT 1,
    \\  last_utc_sec INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
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
    \\CREATE TABLE IF NOT EXISTS table_last_update(
    \\  table_name TEXT NOT NULL UNIQUE,
    \\  last_update_timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS icon_failed(
    \\  feed_id INTEGER NOT NULL UNIQUE,
    \\  last_failed_utc INTEGER DEFAULT (strftime('%s', 'now')),
    \\  last_msg TEXT DEFAULT NULL,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
    \\) STRICT;
    ,
    \\CREATE TABLE IF NOT EXISTS feed_request_failed(
    \\  feed_id INTEGER NOT NULL,
    \\  utc_sec INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    \\  reason TEXT DEFAULT NULL,
    \\  FOREIGN KEY(feed_id) REFERENCES feed(feed_id) ON DELETE CASCADE
    \\) STRICT;
    ,

    // Create triggers
    \\CREATE TRIGGER IF NOT EXISTS tag_update_trigger
    \\   AFTER UPDATE ON tag
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'tag' AND OLD.name != NEW.name;
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS tag_delete_trigger
    \\   AFTER DELETE ON tag
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'tag';
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS tag_insert_trigger 
    \\   AFTER INSERT ON tag
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'tag';
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS feed_update_trigger
    \\   AFTER UPDATE ON feed
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'feed' AND (
    \\    OLD.title != NEW.title OR
    \\    OLD.feed_url != NEW.feed_url OR
    \\    OLD.page_url != NEW.page_url OR
    \\    OLD.icon_id != NEW.icon_id
    \\  );
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS feed_delete_trigger
    \\   AFTER DELETE ON feed
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'feed';
    \\  delete from icon where OLD.icon_id == icon.icon_id and (select count(*) == 0 from feed where OLD.icon_id == feed.icon_id);
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS feed_tag_delete_trigger
    \\   AFTER DELETE ON feed_tag
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'feed';
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS feed_tag_insert_trigger
    \\   AFTER INSERT ON feed_tag
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'feed';
    \\END;
};

fn testAddFeed(storage: *Storage, content: []const u8, allocator: Allocator) !Storage.AddFeed {
    const url = "http://localhost:8282/rss2.xml";

    var p = parse.init(std.testing.io, content);
    const parsed = try p.parse(allocator, null, .{
        .feed_url = try std.Uri.parse(url),
    });

    const add_opts: Storage.AddOptions = .{ .feed_opts = .{} };

    const feed = try storage.addFeed(parsed, add_opts);

    {
        const count = try storage.sql_db.raw("select count(*) from feed", .{}).get(usize) ;
        try std.testing.expectEqual(1, count.?);
    }

    {
        const count = try storage.sql_db.raw("select count(*) from item", .{}).get(usize) ;
        try std.testing.expectEqual(4, count.?);
    }

    return feed;
}

// Run all (most?) Storage functions to see if queries are correct.
test "Storage:all" {
    // std.testing.log_level = .debug;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = @embedFile("rss2.xml");
    var storage = try Storage.init(std.testing.io, std.testing.allocator, null);
    defer storage.deinit();
    const feed = try testAddFeed(&storage, content, arena.allocator());

    {
        const items = try storage.get_items_latest_added(arena.allocator());
        try std.testing.expectEqual(4, items.len);
    }

    {
        const value = try storage.get_latest_change();
        try std.testing.expect(value != null);
    }

    {
        const value = try storage.feed_last_update(feed.feed_id);
        try std.testing.expect(value != null);
    }

    {
        const value = try storage.next_update_feed(feed.feed_id);
        try std.testing.expect(value != null);
    }

    {
        const value = try storage.feed_with_id(arena.allocator(), feed.feed_id);
        try std.testing.expect(value != null);
    }

    {
        const value = try storage.feeds_search_has_previous(arena.allocator(), .{
            .before = feed.feed_id,
        });
        try std.testing.expectEqual(false, value);
    }

    {
        const value = try storage.feeds_search_complex(arena.allocator(), .{});
        try std.testing.expectEqual(1, value.len);
    }

    {
        const value = try storage.get_feeds_with_ids(arena.allocator(), &.{feed.feed_id});
        try std.testing.expectEqual(1, value.len);
    }

    {
        const value1 = try storage.getLatestFeedItemsWithFeedId(feed.feed_id, .{});
        try std.testing.expectEqual(4, value1.len);

        try storage.updateAndRemoveFeedItems(value1);

        const value = try storage.feed_items_with_feed_id(arena.allocator(), feed.feed_id);
        // NOTE: 5 because one item does't have any kind of identifier
        try std.testing.expectEqual(5, value.len);
    }

    {
        const feed_change = try storage.get_latest_feed_change(feed.feed_id);
        try std.testing.expect(feed_change != null);

        try storage.updateLastUpdate(feed.feed_id);
        try storage.update_feed_timestamp(.{
            .feed_id = feed.feed_id,
            .feed_url = undefined,
            .updated_timestamp = 0,
        });
        try storage.update_feed_fields(arena.allocator(), .{
            .feed_id = feed.feed_id,
            .title = "update_feed_fields_title",
            .page_url = "http://valid.com",
            .tags = &.{},
        });

        var inputs = [_][]const u8 {"localhost"};
        const latest_feeds = try storage.getLatestFeedsWithUrl(arena.allocator(), &inputs, .{});
        try std.testing.expectEqual(1, latest_feeds.len);

        const feeds_with_url = try storage.getFeedsWithUrl(arena.allocator(), "localhost");
        try std.testing.expectEqual(latest_feeds.len, feeds_with_url.len);
        try std.testing.expectEqualDeep(latest_feeds[0], feeds_with_url[0]);

        const feeds_to_update = try storage.getFeedsToUpdate(arena.allocator(), "localhost", .{
            .force = true,
        });
        try std.testing.expectEqual(1, feeds_to_update.len);
    }


    { // Icon tests
        const missing = try storage.feed_icons_missing(arena.allocator());
        try std.testing.expectEqual(1, missing.len);

        const icon_url = "http://localhost/icon.png";
        const icon_uri = try std.Uri.parse(icon_url);
        var icon: types.Icon = .init(icon_uri, "<icon_content>", null);
        const icon_id = try storage.icon_upsert(icon);
        try std.testing.expect(icon_id != .unassigned);
        _ = try storage.icon_upsert(icon);

        const feed_id_null = try storage.feed_id_by_icon_id(icon_id);
        try std.testing.expectEqual(null, feed_id_null);

        try storage.feed_icon_update(feed.feed_id, icon_id);

        icon.data = "<icon_content_updated>";
        try storage.icon_update(icon_uri, icon);

        const icon_id_from_url = try storage.icon_get_id(icon_url);
        try std.testing.expectEqual(icon_id, icon_id_from_url);

        const icons = try storage.icon_all(arena.allocator());
        try std.testing.expectEqual(1, icons.len);
        try std.testing.expectEqualStrings(icon.data, icons[0].icon_data);

        const value = try storage.icon_by_id(arena.allocator(), icon_id);
        try std.testing.expectEqualStrings(icon.data, value.?.icon_data);

	try storage.icon_failed_add(.{
            .feed_id = feed.feed_id,
            .last_msg = "test failed",
	});

        const failed = try storage.feed_icons_failed(arena.allocator());
        try std.testing.expectEqual(1, failed.len);

        try storage.icon_failed_remove(feed.feed_id);
        const failed_after = try storage.feed_icons_failed(arena.allocator());
        try std.testing.expectEqual(0, failed_after.len);


        try storage.feed_icon_update(feed.feed_id, null);
        try storage.icons_remove_unused();
        const icons_empty = try storage.icon_all(arena.allocator());
        try std.testing.expectEqual(0, icons_empty.len);
    }

    { // Failed feed requests tests
        try storage.request_failed_add(feed.feed_id, "test failed");
        const failed_requests = try storage.request_failed_slice(arena.allocator(), feed.feed_id);
        try std.testing.expectEqual(1, failed_requests.len);

        try storage.request_failed_remove(feed.feed_id);

        const failed_ids = try storage.request_failed_ids(arena.allocator());
        try std.testing.expectEqual(0, failed_ids.len);
    }

    { // test rate limits
        const next_ts = try storage.next_update_timestamp();
        try std.testing.expect(next_ts.? > 0);

	const rate_utc = 1;
        try storage.rate_limit_add(feed.feed_id, rate_utc);
        const count = try storage.sql_db.raw("select count(*) from rate_limit", .{}).fetchOne(u64);
        try std.testing.expectEqual(1, count.?);

        const next_rate_ts = try storage.next_update_timestamp();
        try std.testing.expectEqual(rate_utc, next_rate_ts.?);

        try storage.rate_limit_remove(feed.feed_id);
        const count_empty = try storage.sql_db.raw("select count(*) from rate_limit", .{}).fetchOne(u64);
        try std.testing.expectEqual(0, count_empty.?);

        const next_feed_ts = try storage.next_update_feed(feed.feed_id);
        try std.testing.expectEqual(next_ts.?, next_feed_ts.?);
    }

    { // test html selector
        const has_html_1 = try storage.html_selector_has(feed.feed_id);
        try std.testing.expectEqual(false, has_html_1);

        try storage.html_selector_add(feed.feed_id, .{
            .selector_container = ".container",
            .selector_link = ".link_first",
            .date_format = null,
        });

        try storage.html_selector_add(feed.feed_id, .{
            .selector_container = ".container",
            .selector_link = ".link",
        });

        const has_html_2 = try storage.html_selector_has(feed.feed_id);
        try std.testing.expectEqual(true, has_html_2);

        const feed_html_info = try storage.html_selector_get(arena.allocator(), feed.feed_id);
        try std.testing.expectEqualStrings(feed_html_info.?.selector_container, ".container");
        try std.testing.expectEqualStrings(feed_html_info.?.selector_link.?, ".link");
        try std.testing.expectEqual(feed_html_info.?.date_format, null);
    }

    { // test url rules
    	const uri = try std.Uri.parse("http://match_host.dev/match_path");
    	const rule_opts: Storage.Rule = .{
            .match_host = uri.host.?.percent_encoded,
            .match_path = uri.path.percent_encoded,
            .result_host = "result_host",
            .result_path = "/result_path",
        };
        try storage.rule_add(rule_opts);
        try storage.rule_add(rule_opts);

        const rule_exists = try storage.has_rule(rule_opts);
        try std.testing.expect(rule_exists);

        const r = try storage.get_add_rule(arena.allocator(), uri);
        try std.testing.expect(r != null);

        const rules_for_host = try storage.get_rules_for_host(arena.allocator(), rule_opts.match_host);
        try std.testing.expectEqual(rules_for_host.len, 1);
    
        const rules_all = try storage.rules_all(arena.allocator());
        try std.testing.expectEqual(rules_all.len, 1);

        const rules_filtered = try storage.rules_filter(arena.allocator(), "match");
        try std.testing.expectEqual(rules_filtered.len, 1);
        const rule_id = rules_filtered[0].add_rule_id;
    
        try storage.rule_remove(rule_id);
        const no_rule = try storage.has_rule(rule_opts);
        try std.testing.expect(!no_rule);
    }

    { // tags tests
        const change_1 = try storage.get_tags_change();
        try std.testing.expect(change_1 != null);

        var add_tags = [_][]const u8{"t1", "t2", "t3"};
        try storage.tags_add(&add_tags);


        const ids = try storage.tags_all_with_ids(arena.allocator());
        try std.testing.expectEqual(add_tags.len , ids.len);

        const first_id = ids[0].tag_id;
        const first_name = "t1_updated";
        try storage.tag_update(.{ .tag_id = first_id, .name = first_name });

        const first_tag = try storage.tag_with_id(arena.allocator(), first_id);
        try std.testing.expectEqualStrings(first_name, first_tag.?.name);

        { // feed tags tests
            var feed_tag_ids = [_]types.SqliteId{first_id, ids[1].tag_id};
            try storage.tags_feed_add(feed.feed_id, &feed_tag_ids);
            const feed_tags = try storage.feed_tags(arena.allocator(), feed.feed_id);
            try std.testing.expectEqual(2 , feed_tags.len);

            var remove_ids = [_][]const u8 {"t2"};
            try storage.tags_feed_remove(feed.feed_id, &remove_ids);

            const feed_tags_1 = try storage.feed_tags(arena.allocator(), feed.feed_id);
            try std.testing.expectEqual(1, feed_tags_1.len);
        }

        try storage.tags_remove_with_id(first_id);
        const all = try storage.tags_all(arena.allocator());
        try std.testing.expectEqual(add_tags.len - 1, all.len);

        var list_of_tags = [_][]const u8{"t2"};
        try storage.tags_remove(&list_of_tags);
        var buf: [1]types.SqliteId = undefined;
        const name_to_ids = try storage.tags_ids(&add_tags, &buf);
        try std.testing.expectEqual(name_to_ids.len, buf.len);

        const change_2 = try storage.get_tags_change();
        try std.testing.expect(change_2.? >= change_1.?);
    }

    { // delete feed
        try storage.deleteFeed(feed.feed_id);

        {
            const count = try storage.sql_db.raw("select count(*) from feed", .{}).get(usize);
            try std.testing.expectEqual(0, count.?);
        }

        {
            const count = try storage.sql_db.raw("select count(*) from item", .{}).get(usize);
            try std.testing.expectEqual(0, count.?);
        }
    }

}
