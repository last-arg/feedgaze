const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const types = @import("./feed_types.zig");
const Feed = types.Feed;
const IconRender = types.IconRender;
const Icon = types.Icon;
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
const parse = @import("./feed_parse.zig");
const app_config = @import("app_config.zig");
const util = @import("util.zig"); 
const is_url = util.is_url; 
const is_url_or_data = util.is_url_or_data; 

pub const Storage = struct {
    const Self = @This();
    sql_db: sql.Database,
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

    pub fn init(path: ?[*:0]const u8) !Self {
        const db = try sql.Database.open(if (path) |p| .{.path = p} else .{});
        errdefer db.close();

        try setupDb(&db);

        return .{
            .sql_db = db,
        };
    }

    pub fn deinit(self: *Self) void {
        self.sql_db.close();
    }

    // Sqlite config for servers: https://kerkour.com/sqlite-for-servers
    fn setupDb(db: *const sql.Database) !void {
        errdefer std.log.err("Failed to create new database", .{});

        // NOTE: permanent pragmas:
        // - application_id
        // - journal_mode (when enabling or disabling WAL mode)
        // - schema_version
        // - user_version
        // - wal_checkpoint
        try db.exec("PRAGMA foreign_keys = 1", .{});
        try db.exec("PRAGMA journal_mode = WAL", .{});
        try db.exec("PRAGMA synchronous = normal", .{});
        try db.exec("PRAGMA temp_store = 2", .{});
        try db.exec("PRAGMA mmap_size = 30000000000", .{});
        try db.exec("PRAGMA cache_size = -32000", .{});
        try db.exec("PRAGMA cache_size = -32000", .{});
        if (@import("builtin").mode != .debug) {
            try db.exec("PRAGMA busy_timeout = 1000", .{});
        }

        try setupTables(db);
        try initData(db);
    }

    fn setupTables(db: *const sql.Database) !void {
        errdefer std.log.err("Failed to create database tables", .{});
        inline for (tables) |query| {
            db.exec(query, .{}) catch |err| {
                print_sql_error(db, query);
                return err;
            };
        }
    }

    fn print_sql_error(db: *const sql.Database, query: []const u8) void {
        std.log.err("SQL_ERROR: {?s}\n Failed query:\n{s}\n", .{ db.errmsg(), query });
    }

    fn initData(db: *const sql.Database) !void {
        // TODO: move this to where table_last_update table is created?
        const query =
        \\INSERT OR IGNORE INTO table_last_update (table_name) 
        \\VALUES 
        \\  ('tag'),
        \\  ('feed'),
        \\  ('feed_request_failed')
        ;
        db.exec(query, .{}) catch |err| {
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
        icon_id: IconRender.ID,
    };

    pub fn addFeed(self: *Self, parsed_feed: parse.ValidFeed, opts: AddOptions) !AddFeed {
        var parsed = parsed_feed;
        const feed_opts = opts.feed_opts;

        try self.sql_db.exec("BEGIN DEFERRED", .{});
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
        try self.sql_db.exec("COMMIT", .{});

        return .{.feed_id = feed_id, .icon_id = parsed.feed.icon_id};
    }

    const ContentType = parse.ContentType;
    pub fn updateFeedAndItems(
        self: *Self,
        parsed: parse.ValidFeed,
        feed_update_input: FeedUpdate,
    ) !void {
        const feed_id = parsed.feed.feed_id;
        try self.sql_db.exec("BEGIN DEFERRED", .{});
        try self.update_feed_timestamp(parsed.feed);
        try self.rate_limit_remove(feed_id);
        try self.request_failed_remove(feed_id);
        try self.updateFeedUpdate(feed_id, feed_update_input, parsed.item_interval);

        if (parsed.items.len == 0) {
            try self.sql_db.exec("COMMIT", .{});
            return;
        }

        try self.updateAndRemoveFeedItems(parsed.items);
        try self.sql_db.exec("COMMIT", .{});
    }

    pub fn rate_limit_remove(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        try self.sql_db.exec("DELETE FROM rate_limit WHERE feed_id = ?", .{@backingInt(feed_id)});
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
        
        try self.sql_db.exec(query, .{ @backingInt(feed_id), utc_sec});
    }

    pub fn request_failed_add(self: *Self, feed_id: Feed.ID, reason: []const u8) !void {
        std.debug.assert(feed_id != .unassigned);
        const query = "INSERT INTO feed_request_failed (feed_id, reason) VALUES (?, ?)";

        try self.sql_db.exec(query, .{@backingInt(feed_id), sql.text(reason)});
    }

    pub fn request_failed_remove(self: *Self, feed_id: Feed.ID) !void {
        try self.sql_db.exec("DELETE FROM feed_request_failed WHERE feed_id = ?", .{@backingInt(feed_id)});
    }

    pub fn request_failed_ids(self: *Self, allocator: Allocator) ![]const Feed.ID {
        const query =
        \\select distinct(feed_id) as val from feed_request_failed
        ;

        var res = try std.array_list.Managed(Feed.ID).initCapacity(allocator, 10);
        errdefer res.deinit();

        var stmt = try self.sql_db.prepare(struct{}, struct{val: u64}, query);
        defer stmt.finalize();

        while (try stmt.step()) |row| {
            try res.append(@fromBackingInt(row.val));
        }

        return res.toOwnedSlice();
    }

    const FeedFailedRequest = struct {
        utc_sec: i64,
        reason: []const u8,

        pub const Raw = struct {
            utc_sec: i64,
            reason: sql.Text,

            pub fn strings_len(raw: *const Raw) u64 {
                return raw.reason.data.len;
            }
        };

	pub fn from_raw(buf: []u8, raw: Raw) !FeedFailedRequest {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll(raw.reason.data) catch unreachable;

            return .{
                .utc_sec = raw.utc_sec,
                .reason = w.buffered(),
            };
	}
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

        return try all(&self.sql_db, FeedFailedRequest, allocator, query, .{@backingInt(feed_id)});
    }

    pub const FeedFailedRequestWithID = struct {
        feed_id: Feed.ID,
        utc_sec: i64,
        reason: []const u8,

        pub const Raw = struct {
            feed_id: u64,
            utc_sec: i64,
            reason: sql.Text,

            pub fn strings_len(raw: *const Raw) u64 {
                return raw.reason.data.len;
            }
        };

	pub fn from_raw(buf: []u8, raw: Raw) !FeedFailedRequestWithID {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll(raw.reason.data) catch unreachable;

            return .{
                .feed_id = @fromBackingInt(raw.feed_id),
                .utc_sec = raw.utc_sec,
                .reason = w.buffered(),
            };
	}
    };

    pub fn request_failed_all(self: *Self, allocator: Allocator) ![]const FeedFailedRequestWithID {
        const query =
            \\select fr1.feed_id, fr2.utc_sec, fr2.reason
            \\from (select feed_id, max(utc_sec) max_utc_sec from feed_request_failed group by feed_id order by utc_sec DESC) fr1
            \\left join feed_request_failed fr2 
            \\on fr1.feed_id = fr2.feed_id
            \\order by fr1.max_utc_sec DESC, fr2.utc_sec DESC
        ;

        return try all(&self.sql_db, FeedFailedRequestWithID, allocator, query, .{});
    }

    pub fn request_failed_feeds(self: *Self, allocator: Allocator) ![]const Feed {
        const capacity = 10;
        const query =
        \\select feed_id, title, feed_url, page_url, icon_id, updated_timestamp
        \\from feed
        \\where feed_id in (select distinct(feed_id) from feed_request_failed)
        ;

        return try fetch_all_feeds(allocator, &self.sql_db, query, .{}, capacity);
    }

    pub fn insertFeed(self: *Self, feed: Feed) !Feed.ID {
        const query =
            \\INSERT INTO feed (title, feed_url, page_url, icon_id, updated_timestamp)
            \\VALUES (
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?
            \\) ON CONFLICT(feed_url) DO NOTHING
            \\RETURNING feed_id as val
        ;

        var buf: [2 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{f}", .{feed.feed_url});
        const feed_url = w.buffered();
        const page_url_text = blk: {
            if (feed.page_url) |page_url| {
                try w.print("{f}", .{page_url});
                break :blk sql.text(w.buffered()[feed_url.len..]);
            }
            break :blk null;
       };

        const feed_id = (try one(u64, &self.sql_db, undefined, query, .{
             if (feed.title) |title| sql.text(title) else null,
             sql.text(feed_url),
             page_url_text,
             if (feed.icon_id.is_valid()) @backingInt(feed.icon_id) else null,
             feed.updated_timestamp,
        })) orelse return Error.FeedExists;

        return @fromBackingInt(feed_id);
    }

    pub fn get_feed_id_with_url(self: *Self, url: []const u8) !?Feed.ID {
        const query =
            \\SELECT feed_id as val FROM feed WHERE feed_url = :url OR page_url = :url;
        ;
        if (try one(u64, &self.sql_db, undefined, query, .{ .url = sql.text(url) })) |feed_id| {
            return @fromBackingInt(feed_id);
        }
        return null;
    }
    
    pub fn getFeedsWithUrl(self: *Self, allocator: Allocator, url: []const u8) ![]const Feed {
        const query =
            \\SELECT feed_id, title, feed_url, page_url, icon_id, updated_timestamp FROM feed
            \\WHERE feed_url LIKE '%' || :url || '%' OR page_url LIKE '%' || :url || '%'
        ;

        return try fetch_all_feeds(allocator, &self.sql_db, query, Test{.url = sql.text(url)}, 10);
    }
    const Test = struct{url: sql.Text};

    pub fn getLatestFeedsWithUrl(self: *Self, allocator: Allocator, inputs: [][]const u8, opts: ShowOptions) ![]const Feed {
        const query = std.fmt.comptimePrint(
            \\SELECT feed_id, title, feed_url, page_url, icon_id, updated_timestamp FROM feed
            \\{{s}}
            \\ORDER BY updated_timestamp DESC LIMIT :limit
        , .{});

        const query_like = "WHERE feed_url LIKE '%' || :term || '%' OR page_url LIKE '%' || :term || '%'";
        var buf: [query.len + query_like.len]u8 = undefined;

        if (inputs.len > 0) {
            const query_args = .{.limit = opts.limit, .term = sql.text(inputs[0])};
            const query_result = std.fmt.bufPrint(&buf, query, .{query_like}) catch unreachable;

            return try fetch_all_feeds(allocator, &self.sql_db, query_result, query_args, @intCast(opts.limit));
        }

        const query_args = .{.limit = opts.limit};
        const query_result = std.fmt.bufPrint(&buf, query, .{""}) catch unreachable;

        return try fetch_all_feeds(allocator, &self.sql_db, query_result, query_args, @intCast(opts.limit));
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
        const query = "select exists (SELECT 1 as val from feed where feed_url = :url OR page_url = :url)";

        if (try one(u32, &self.sql_db, undefined, query, .{.url = sql.text(url)})) |val| {
            return val == 1;
        }

        return false;
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
                \\  (unixepoch() >= last_update + {s})
                \\)
            , .{rate_limit_iif_utc_sec, failed_request_query, iif_update_interval}));
        }

        const Params = struct {term: sql.Text};
        const query_opts: Params= blk: {
            if (search_term) |term| {
                if (term.len > 0) {
                    const cond_start = if (has_where) " AND " else " WHERE ";
                    storage_arr.appendSliceAssumeCapacity(cond_start);
                    storage_arr.appendSliceAssumeCapacity("(feed.feed_url LIKE '%' || :term || '%' OR feed.page_url LIKE '%' || :term || '%' OR feed.title LIKE '%' || :term || '%')");
                    break :blk .{.term = sql.text(term)};
                }
            }
            break :blk .{.term = sql.text("")};
        };

        storage_arr.appendSliceAssumeCapacity(" GROUP BY item.feed_id");

        const stmt = try self.sql_db.prepare(Params, FeedToUpdate.Raw, storage_arr.items);
        defer stmt.finalize();

        try stmt.bind(query_opts);
        defer stmt.reset();

        var res = try std.array_list.Managed(FeedToUpdate).initCapacity(allocator, 10);
        errdefer res.deinit();

        while (try stmt.step()) |row| {
            // TODO: @allocation improve
            const buf_text = try allocator.alloc(u8, row.strings_len());
            try res.append(try FeedToUpdate.from_raw(buf_text, row));
        }

        return try res.toOwnedSlice();
    }

    pub fn deleteFeed(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        try self.sql_db.exec("DELETE FROM feed WHERE feed_id = :feed_id", .{.feed_id = @intFromEnum(feed_id)});
    }

    pub fn update_feed_timestamp(self: *Self, feed: Feed) !void {
        const query =
            \\UPDATE feed SET updated_timestamp = ?1
            \\WHERE feed_id = ?2;
        ;
        try self.sql_db.exec(query, .{ feed.updated_timestamp, @backingInt(feed.feed_id) });
    }

    pub const FeedFields = struct {
        feed_id: Feed.ID,
        title: []const u8,
        page_url: []const u8,
        icon_id: types.IconRender.ID = .unassigned,
        tags: [][]const u8,
    };

    pub fn update_feed_fields(self: *Self, allocator: Allocator, fields: FeedFields) !void {
        assert(fields.feed_id != .unassigned);
        // Remove tags that aren't part of .tags 
        var buf: [1024]u8 = undefined;
        var buf_cstr: [256]u8 = undefined;

        if (fields.tags.len > 0) {
            var tags_str: std.ArrayList(u8) = .empty;
            defer tags_str.deinit(allocator);

            {
                const tag_cstr = try std.fmt.bufPrintSentinel(&buf_cstr, "{s}", .{fields.tags[0]}, 0);
                const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                const tag_slice = mem.sliceTo(c_str, 0x0);
                try tags_str.appendSlice(allocator, tag_slice);
            }

            for (fields.tags[1..]) |tag| {
                const tag_cstr = try std.fmt.bufPrintSentinel(&buf_cstr, "{s}", .{tag}, 0);
                const c_str = sql.c.sqlite3_snprintf(buf.len, @ptrCast(&buf), "%Q", tag_cstr.ptr);
                const tag_slice = mem.sliceTo(c_str, 0);
                try tags_str.append(allocator, ',');
                try tags_str.appendSlice(allocator, tag_slice);
            }

            const query_fmt = "DELETE FROM feed_tag WHERE feed_id = ? and tag_id not in (select tag_id from tag where name in (?))";
            // TODO: not sure if 'tags_str.items' will work?
            try self.sql_db.exec(query_fmt, .{ @backingInt(fields.feed_id), sql.text(tags_str.items) });
        } else {
            const query = "DELETE FROM feed_tag WHERE feed_id = ?";
            try self.sql_db.exec(query, .{@backingInt(fields.feed_id)});
        }

        // Make sure all tags exist
        try self.tags_add(fields.tags);
        for (fields.tags) |tag| {
            const query = 
            \\insert into feed_tag (feed_id, tag_id) values 
            \\  (?, (select tag_id from tag where name = ? limit 1)) ON CONFLICT DO NOTHING
            ;
            try self.sql_db.exec(query, .{
                @backingInt(fields.feed_id),
                sql.text(tag),
            });
        }

        // Update feed_title and page_url
        const query = 
        \\UPDATE feed 
        \\SET title = ?, page_url = ?, icon_id = ?, updated_timestamp = strftime('%s', 'now')
        \\WHERE feed_id = ?
        ;

        try self.sql_db.exec(query, .{
            sql.text(fields.title),
            sql.text(fields.page_url),
            if (fields.icon_id.is_valid()) @backingInt(fields.icon_id) else null,
            @backingInt(fields.feed_id),
        });
    }

    pub fn hasFeedWithId(self: *Self, feed_id: Feed.ID) !bool {
        assert(feed_id != .unassigned);
        const query = "SELECT EXISTS(SELECT 1 FROM feed WHERE feed_id = ?) as val";
        if (try one(u32, &self.sql_db, undefined, query, .{@backingInt(feed_id) })) |val| {
            return val == 1;
        }
        return false;
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
            \\RETURNING item_id as val
        ;

        var buf_link: [1024]u8 = undefined;
        const len = @min(inserts.len, app_config.max_items);
        for (inserts[0..len], 0..) |*item, i| {
            const link = blk: {
                if (item.link) |link| {
                    break :blk sql.text(try std.fmt.bufPrint(&buf_link, "{f}", .{link}));
                }
                break :blk null;
            };
            if (try one(u64, &self.sql_db, undefined, query, .{
                @backingInt(item.feed_id),
                sql.text(item.title),
                link,
                if (item.id) |id| sql.text(id) else null,
                item.updated_timestamp,
                i,
            })) |item_id| {
                item.item_id = @fromBackingInt(item_id);
            }
        }
        return inserts;
    }

    pub fn getLatestFeedItemsWithFeedId(self: *Self, allocator: Allocator, feed_id: Feed.ID, opts: ShowOptions) ![]const FeedItem {
        assert(feed_id != .unassigned);

        var res = try std.array_list.Managed(FeedItem).initCapacity(allocator, @intCast(opts.@"item-limit"));
        errdefer res.deinit();

        const raw_query =
            \\select feed_id, item_id, title, id, link, updated_timestamp from item
            \\where feed_id = :feed_id
            \\order by position ASC
            \\LIMIT :limit
        ;

        var stmt = try self.sql_db.prepare(
            struct{feed_id: u64, limit: i32},
            FeedItem.Raw,
            raw_query
        );
        defer stmt.finalize();

        try stmt.bind(.{.feed_id = @backingInt(feed_id), .limit = opts.@"item-limit" });
        defer stmt.reset();

        while (try stmt.step()) |row| {
            const buf = try allocator.alloc(u8, row.strings_len()) ;
            res.appendAssumeCapacity(try .from_raw(buf, row));
        }

        return res.toOwnedSlice();
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
        try self.sql_db.exec(query, .{
            @backingInt(feed_id),
            feed_update.update_interval,
            if (feed_update.etag_or_last_modified) |val| sql.text(val) else null,
            item_interval,
        });
    }

    pub fn icons_remove_unused(self: *Self) !void {
        const query =
            \\delete from icon
            \\where icon_id not in
            \\  (select distinct(icon_id) from feed where icon_id not null);
        ;
        try self.sql_db.exec(query, .{});
    }

    pub fn icon_upsert(self: *Self, icon: types.Icon) !IconRender.ID {
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
            \\RETURNING icon_id as val;
        ;

        var buf: [1024]u8 = undefined;
        const icon_url = try std.fmt.bufPrint(&buf, "{f}", .{icon.url});

        const icon_id_opt = try one(u64, &self.sql_db, undefined, query, .{
            sql.text(icon_url),
            sql.blob(icon.data),
            sql.text(icon.etag_or_last_modified_or_hash),
        });

        if (icon_id_opt) |icon_id| {
            return @fromBackingInt(icon_id);
        }

        return .unassigned;
    }

    pub fn updateLastUpdate(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        const query = "update feed_update set last_update = strftime('%s', 'now') where feed_id = ?;";
        try self.sql_db.exec(query, .{@backingInt(feed_id)});
    }

    pub fn updateAndRemoveFeedItems(self: *Self, items: []const FeedItem) !void {
        assert(items.len > 0);
        const feed_id = items[0].feed_id;
        {
            const query = "update item set position = position + ? where feed_id = ?;";
            try self.sql_db.exec(query, .{ items.len, @backingInt(feed_id) });
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
            \\ON CONFLICT(feed_id, link) DO UPDATE SET
            \\  title = excluded.title,
            \\  id = excluded.id,
            \\  updated_timestamp = excluded.updated_timestamp,
            \\  position = excluded.position
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
                    sql.text(try std.fmt.bufPrint(&buf_link, "{f}", .{link}))
                else null;
                try self.sql_db.exec(query_with_id, .{
                    @backingInt(item.feed_id),
                    sql.text(item.title),
                    link,
                    if (item.id) |val| sql.text(val) else null,
                    item.updated_timestamp,
                    i,
                });
            } else {
                try self.sql_db.exec(query_without_id, .{
                    @backingInt(item.feed_id),
                    sql.text(item.title),
                    item.updated_timestamp,
                    i,
                });
            }
        }
    }

    pub fn cleanFeedItems(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        const del_query =
            \\DELETE FROM item WHERE feed_id = ? and position >= ?
        ;
        try self.sql_db.exec(del_query, .{ @backingInt(feed_id), self.options.max_item_count });
    }

    pub fn feed_items_with_feed_id(self: *Self, allocator: Allocator, feed_id: Feed.ID) ![]const FeedItemRender {
        const query = std.fmt.comptimePrint(
            \\select feed_id, title, link, updated_timestamp, created_timestamp
            \\from item where feed_id = ? order by updated_timestamp DESC, position ASC
            \\LIMIT {d}
        , .{app_config.max_items});

        const items = try self.fetch_feed_item_render(allocator, query, .{@backingInt(feed_id)}, .{});
        return items;
    }

    const FeedItemRenderOptions = struct {
        capacity: usize = app_config.max_items,
    };

    fn fetch_feed_item_render(self: *@This(), allocator: Allocator, query: []const u8, args: anytype, opts: FeedItemRenderOptions,) ![]const FeedItemRender {
        _ = opts;
        return all(&self.sql_db, FeedItemRender, allocator, query, args);
    }

    pub fn tags_all(self: *Self, allocator: Allocator) ![]const []const u8 {
        const query = "SELECT name as val FROM tag ORDER BY name ASC;";

        return try all(&self.sql_db, []const u8, allocator, query, .{});
    }

    pub fn tag_with_id(self: *Self, allocator: Allocator, tag_id: types.SqliteId) !?TagResult {
        const query = "SELECT tag_id, name FROM tag where tag_id = ?;";

        if (try one(TagResult, &self.sql_db, allocator, query, .{@backingInt(tag_id)})) |row| {
            return row;
        }
        return null;
    }

    pub fn tag_update(self: *Self, data: TagResult) !void {
        const query =
            \\UPDATE tag SET
            \\  name = ?1
            \\WHERE tag_id = ?2
        ;
        try self.sql_db.exec(query, .{sql.text(data.name), @backingInt(data.tag_id)});
    }
        
    const TagResult = struct{
        tag_id: types.SqliteId,
        name: []const u8,

        pub const Raw = struct {
            tag_id: u64,
            name: sql.Text,

            pub fn strings_len(raw: *const Raw) u64 {
                return raw.name.data.len;
            }
        };

        pub fn from_raw(buf: []u8, raw: Raw) !TagResult {
            var result: TagResult = .{
                .tag_id = @fromBackingInt(raw.tag_id),
                .name = undefined,
            };

            var w: std.Io.Writer = .fixed(buf);

            w.writeAll(raw.name.data) catch unreachable;
            result.name = w.buffered();

            return result;
        }
    };

    pub fn tags_all_with_ids(self: *Self, allocator: Allocator) ![]const TagResult {
        const query = "select * from tag order by name ASC";

        return all(&self.sql_db, TagResult, allocator, query, .{});
    }

    pub fn tags_remove_with_id(self: *Self, tag_id: types.SqliteId) !void {
        const query =
        \\delete from tag where tag_id = ?
        ;
        try self.sql_db.exec(query, .{@backingInt(tag_id)});
    }

    pub fn feed_tags(self: *Self, allocator: Allocator, feed_id: Feed.ID) ![]const []const u8 {
        assert(feed_id != .unassigned);
        const query = 
        \\select name as val from tag where tag_id in (
        \\  select distinct(tag_id) from feed_tag where feed_id = ?
        \\)
        ;
        return try all(&self.sql_db, []const u8, allocator, query, .{@backingInt(feed_id)});
    }
        
    pub fn tags_add(self: *Self, tags: [][]const u8) !void {
        const query = "INSERT INTO tag (name) VALUES(?) ON CONFLICT DO NOTHING;";
        for (tags) |tag| {
            assert(tags.len > 0);
            try self.sql_db.exec(query, .{sql.text(tag)});
        }
    }

    pub fn tags_ids(self: *Self, tags: [][]const u8, buf: []types.SqliteId) ![]types.SqliteId {
        const query = "select tag_id as val from tag where name = ?;";
        var i: usize = 0;
        for (tags) |tag| {
            if (try one(u64, &self.sql_db, undefined, query, .{sql.text(tag)}) ) |value| {
                buf[i] = @fromBackingInt(value);
                i += 1;
            }
        }
        return buf[0..i];
    }

    pub fn tags_remove(self: *Self, tags: [][]const u8) !void {
        const query = "DELETE FROM tag WHERE name = ?";
        for (tags) |tag| {
            assert(tag.len > 0);
            try self.sql_db.exec(query, .{sql.text(tag)});
        }
    }

    pub fn tags_feed_add(self: *Self, feed_id: Feed.ID, tag_ids: []types.SqliteId) !void {
        assert(feed_id != .unassigned);
        const query = "INSERT INTO feed_tag (feed_id, tag_id) VALUES (?, ?) ON CONFLICT DO NOTHING";
        for (tag_ids) |tag_id| {
            try self.sql_db.exec(query, .{ @backingInt(feed_id), @backingInt(tag_id) });
        }
    }

    pub fn tags_feed_remove(self: *Self, feed_id: Feed.ID, tags: [][]const u8) !void {
        assert(feed_id != .unassigned);
        const query = "DELETE FROM feed_tag WHERE feed_id = ? AND tag_id = (select tag_id from tag where name = ?)";
        for (tags) |tag| {
            try self.sql_db.exec(query, .{@backingInt(feed_id), sql.text(tag)});
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
                const query_start = "SELECT tag_id FROM tag where name in (?";
                const query_pos = ",?";
                const query_end = ")";
                const query_len = query_start.len + query_end.len + (args.tags.len - 1) * query_pos.len;
                var query: std.ArrayList(u8) = try .initCapacity(allocator, query_len);
                defer query.deinit(allocator);

                query.appendSliceAssumeCapacity(query_start);

                for (1..args.tags.len) |_| {
                    query.appendSliceAssumeCapacity(query_pos);
                }

                query.appendSliceAssumeCapacity(query_end);

                break :blk try all(&self.sql_db, u64, allocator, query.items, .{});
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

                const value_cstr = try std.mem.printSentinel(&buf_cstr, "{s}", .{value_trimmed}, 0);
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

        return try fetch_all_feeds(allocator, &self.sql_db, query, .{}, app_config.query_feed_limit);
    }

    pub fn feeds_search_has_previous(self: *Self, allocator: Allocator, args: FeedSearchArgs) !bool {
        assert(args.before != .unassigned);

        const query_where = try self.search_query_where(allocator, args);
        defer allocator.free(query_where);
        const query_fmt = 
        \\select exists(SELECT 1 FROM feed {s}
        \\ORDER BY updated_timestamp DESC, feed_id DESC LIMIT 1) as val
        ;
        const query = try std.fmt.allocPrint(allocator, query_fmt, .{query_where});
        defer allocator.free(query);
        const result = try one(u32, &self.sql_db, undefined, query, .{}) orelse 0;
        return result == 1;
    }
    
    const after_cond_raw =
    \\AND ((updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d}) AND feed_id < {[id]d})
    \\      OR updated_timestamp < (select updated_timestamp from feed where feed_id = {[id]d})) 
    ;

    pub fn feed_with_id(self: *Self, allocator: Allocator, feed_id: Feed.ID) !?Feed {
        assert(feed_id != .unassigned);
        const query = 
        \\SELECT feed_id, title, feed_url, page_url, icon_id, updated_timestamp FROM feed
        \\WHERE feed_id = ?1
        ;

        const feed = try one(Feed, &self.sql_db, allocator, query, .{@backingInt(feed_id)})
           orelse return null;

        return feed;
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
        \\RETURNING host_id as val;
        ;

        const match_host_id = try one(u64, &self.sql_db, undefined, query_insert_host, .{sql.text(rule.match_host)})
            orelse return error.AddRuleNoMatchHostId;

        const result_host_id = blk: {
            if (!mem.eql(u8, rule.match_host, rule.result_host)) {
                break :blk try one(u64, &self.sql_db, undefined, query_insert_host, .{sql.text(rule.result_host)})
                    orelse return error.AddRuleNoResultHostId;
            }
            break :blk match_host_id;
        };

        const query_insert_rule = 
        \\insert or ignore into 
        \\  add_rule(match_host_id, match_path, result_host_id, result_path) 
        \\  values (?, ?, ?, ?);
        ;
        try self.sql_db.exec(query_insert_rule, .{match_host_id, sql.text(rule.match_path), result_host_id, sql.text(rule.result_path)});
    }

    const RuleMatchStr = struct {
        match_url: []const u8,
        result_url: []const u8,

        pub const Raw = struct {
            match_url: sql.Text,
            result_url: sql.Text,

            pub fn strings_len(self: *const Raw) u64 {
                return self.match_url.data.len + self.result_url.data.len;
            }
        };

        pub fn from_raw(buf: []u8, raw: Raw) !RuleMatchStr {
            var result: RuleMatchStr = .{
                .match_url = undefined,
                .result_url = undefined,
            };

            var w: std.Io.Writer = .fixed(buf);

            w.writeAll(raw.match_url.data) catch unreachable;
            result.match_url = w.buffered();

            const start = w.buffered().len;
            w.writeAll(raw.result_url.data) catch unreachable;
            result.result_url = w.buffered()[start..];

            return result;
        }
    };

    pub fn rules_all(self: *Self, allocator: Allocator) ![]const RuleMatchStr {
        const query = 
        \\select 
        \\(select name from add_rule_host where host_id = add_rule.match_host_id 
        \\) || match_path as match_url,
        \\(select name from add_rule_host where host_id = add_rule.result_host_id 
        \\) || result_path as result_url
        \\from add_rule
        ;
        return try all(&self.sql_db, RuleMatchStr, allocator, query, .{});
    }

    const RuleFilterMatch = struct {
        add_rule_id: u64,
        match_url: []const u8,
        result_url: []const u8,

        pub const Raw = struct {
            add_rule_id: u64,
            match_url: sql.Text,
            result_url: sql.Text,

            pub fn strings_len(self: *const Raw) u64 {
                return self.match_url.data.len + self.result_url.data.len;
            }
        };

        pub fn from_raw(buf: []u8, raw: Raw) !RuleFilterMatch {
            var result: RuleFilterMatch = .{
                .add_rule_id = raw.add_rule_id,
                .match_url = undefined,
                .result_url = undefined,
            };

            var w: std.Io.Writer = .fixed(buf);

            w.writeAll(raw.match_url.data) catch unreachable;
            result.match_url = w.buffered();

            const start = w.buffered().len;
            w.writeAll(raw.result_url.data) catch unreachable;
            result.result_url = w.buffered()[start..];

            return result;
        }
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
        return try all(&self.sql_db, RuleFilterMatch, allocator, query_fmt, .{sql.text(filter)});
    }
    
    pub fn rule_remove(self: *Self, add_rule_id: u64) !void {
        try self.sql_db.exec("DELETE FROM add_rule WHERE add_rule_id = ?", .{add_rule_id});
    }

    pub fn has_rule(self: *Self, rule: Rule) !bool {
        const query =
            \\select exists(select 1 from add_rule where
            \\match_path = ?1 AND result_path = ?2
            \\AND (select host_id from add_rule_host where name = ?3)
            \\AND (select host_id from add_rule_host where name = ?4)) as val
        ;
        if (try one(u32, &self.sql_db, undefined, query, .{
            sql.text(rule.match_path), sql.text(rule.result_path),
            sql.text(rule.match_host), sql.text(rule.result_host),
        })) |val| {
            return val == 1;
        }

        return false;
    }

    const AddRule = @import("add_rule.zig");
    pub fn get_rules_for_host(self: *Self, allocator: Allocator, host: []const u8) ![]const AddRule.RuleWithHost {
        const query_select_host = "SELECT host_id as val FROM add_rule_host WHERE name = ?";
        const host_id = try one(u64, &self.sql_db, undefined, query_select_host, .{sql.text(host)}) orelse return &.{};
        // TODO: should be able to combine query_select_host with query
        const query = 
        \\select 
        \\  match_path,
        \\  (select name from add_rule_host where host_id = add_rule.result_host_id) as result_host, 
        \\  result_path
        \\from add_rule 
        \\where match_host_id = ?;
        ;

        return try all(&self.sql_db, AddRule.RuleWithHost, allocator, query, .{host_id});
    }

    // 259200 - 3 days in seconds
    const rate_limit_iif_utc_sec =
    \\cast(iif(count < 3, next_utc_sec, 
    \\  max(next_utc_sec,
    \\    last_utc_sec + min(3600 * (count * count), 259200)
    \\  )
    \\) as INTEGER)
    ;

    const select_request_failed = std.fmt.comptimePrint(
    \\select iif(count(*) < 7
    \\    , max(utc_sec) + min(3600 * (count(*) * count(*)), 259200)
    \\    , {d}
    \\  ) as result
    \\  from feed_request_failed
    \\
    , .{@import("zdt").Datetime.unix_s_max});

    const failed_request_utc_sec = comptimePrint(
    \\select min(result) from (
    \\  {s}
    \\  group by feed_id
    \\)
    , .{select_request_failed})
    ;

    const iif_update_interval = comptimePrint(
        \\iif(update_interval > item_interval, min(update_interval, {d}), item_interval)
    , .{types.seconds_in_10_days});

    pub fn next_update_timestamp(self: *Self) !?i64 {
        const query = comptimePrint(
        \\select min(val) as val from (
        \\  select last_update + {s} as val from feed_update
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
        , .{iif_update_interval, rate_limit_iif_utc_sec, failed_request_utc_sec})
        ;

        if (try one(i64, &self.sql_db, undefined, query, .{})) |val| {
            return val;
        }

        return null;
    }

    // NOTE: null means that there have been to many failed feed requests in a row
    pub fn next_update_feed(self: *Self, feed_id: Feed.ID) !?i64 {
        assert(feed_id != .unassigned);
        const query = comptimePrint(
            \\select case
            \\  when count(*) >= 7 then null
            \\  when count(*) > 0 then max(utc_sec) + min(3600 * (count(*) * count(*)), 259200)
            \\  else ifnull((select case
            \\           when count >= 3 then max(next_utc_sec, last_utc_sec + min(3600 * (count * count), 259200))
            \\           when count > 0 then next_utc_sec
            \\         end
            \\         from rate_limit where feed_id = ?1)
            \\         , (select last_update + {s} from feed_update where feed_id = ?1)
            \\       )
            \\end as val
            \\from feed_request_failed
            \\where feed_id = ?1
        , .{iif_update_interval});
        const result = try one(i64, &self.sql_db, undefined, query, .{@backingInt(feed_id)});
        if (result) |val| if (val != 0) {
            return val;
        };
        return null;
    }

    pub fn feed_last_update(self: *Self, feed_id: Feed.ID) !?i64 {
        assert(feed_id != .unassigned);
        return one(i64, &self.sql_db, undefined, "select last_update as val from feed_update where feed_id = ?", .{@backingInt(feed_id)});
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
            \\  (SELECT max(last_update_timestamp) FROM table_last_update
            \\    where table_name in ('feed', 'tag', 'feed_request_failed', 'rate_limit')
            \\  )
            \\) as val;
        ;
        return try one(i64, &self.sql_db, undefined, query, .{});
    }

    pub fn get_latest_feed_change(self: *Self, feed_id: Feed.ID) !?i64 {
        assert(feed_id != .unassigned);
        // NOTE: When to break cache:
        // 1. feed items changed
        // 2. feed fields changed
        // 3. feed update values change
        // 4. tags changed
        const query = 
            \\select max(
            \\  (SELECT max(created_timestamp) FROM item WHERE feed_id = :feed_id),
            \\  (SELECT max(last_update) FROM feed_update WHERE feed_id = :feed_id),
            \\  (SELECT max(updated_timestamp) FROM feed WHERE feed_id = :feed_id),
            \\  (SELECT last_update_timestamp FROM table_last_update where table_name = 'tag'),
            \\  ifnull((SELECT last_utc_sec FROM rate_limit WHERE feed_id = :feed_id), 0)
            \\) as val;
        ;
        const id = @backingInt(feed_id);
        return one(i64, &self.sql_db, undefined, query, .{ .feed_id = id });
    }

    pub fn get_tags_change(self: *Self) !?i64 {
        const query = 
            \\SELECT last_update_timestamp as val FROM table_last_update where table_name = 'tag';
        ;
        return one(i64, &self.sql_db, undefined, query, .{});
    }

    pub fn get_feed_request_failed_change(self: *Self) !?i64 {
        const query = 
            \\SELECT last_update_timestamp as val FROM table_last_update where table_name = 'feed_request_failed';
        ;
        return one(i64, &self.sql_db, undefined, query, .{});
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

        return try fetch_all_feeds(allocator, &self.sql_db, query_al.items, .{}, ids.len);
    }

    fn fetch_all_feeds(allocator: Allocator, db: *const sql.Database, raw_query: []const u8, args: anytype, capacity: usize) ![]const Feed {
        const Params = @TypeOf(args);
        const query = try db.prepare(
            Params,
            Feed.Raw,
            raw_query,
        );
        defer query.finalize();

        try query.bind(args);
        defer query.reset();

        var res = try std.array_list.Managed(Feed).initCapacity(allocator, capacity);
        errdefer res.deinit();

        while (try query.step()) |row| {
            const buf = try allocator.alloc(u8, row.strings_len());
            try res.append(try Feed.from_raw(buf, row));
        }

        return try res.toOwnedSlice();
    }

    pub fn icon_all(self: *Self, allocator: Allocator) ![]const IconRender {
        const query =
        \\SELECT icon_id, icon_url, icon_data, etag_or_last_modified_or_hash
        \\FROM icon
        ;

        return all(&self.sql_db, IconRender, allocator, query, .{});
    }

    pub fn feed_id_by_icon_id(self: *Self, icon_id: IconRender.ID) !?Feed.ID {
        const query =
            \\SELECT feed_id as val FROM feed WHERE icon_id = ?
        ;
        if (try one(u64, &self.sql_db, undefined, query, .{@backingInt(icon_id) })) |feed_id| {
            return @fromBackingInt(feed_id);
        }
        return null;
    }

    const IconMissing = struct {
        feed_id: Feed.ID,
        page_url: std.Uri,

        pub const Raw = struct {
            feed_id: u64,
            page_url: sql.Text,

            pub fn strings_len(self: *const Raw) u64 {
                return self.page_url.data.len;
            }
        };

        pub fn from_raw(buf: []u8, raw: Raw) !IconMissing {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll(raw.page_url.data) catch unreachable;

            return .{
                .feed_id = @fromBackingInt(raw.feed_id),
                .page_url = try std.Uri.parse(w.buffered()),
            };
        }
    };

    pub fn feed_icons_missing(self: *Self, allocator: Allocator) ![]const IconMissing {
        const query =
        \\SELECT feed_id, page_url 
        \\FROM feed WHERE icon_id IS NULL AND page_url IS NOT NULL
        \\AND feed.feed_id NOT IN (select feed_id from icon_failed);
        ;

        return all(&self.sql_db, IconMissing, allocator, query, .{});
    }

    pub const IconFailed = struct {
        feed_id: Feed.ID,
        page_url: std.Uri,
        etag_or_last_modified_or_hash: []const u8,

        pub const Raw = struct {
            feed_id: u64,
            page_url: sql.Text,
            etag_or_last_modified_or_hash: sql.Text,

            pub fn strings_len(self: *const Raw) u64 {
                return self.page_url.data.len + self.etag_or_last_modified_or_hash.data.len;
            }
        };

        pub fn from_raw(buf: []u8, raw: Raw) !IconFailed {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll(raw.page_url.data) catch unreachable;
            const page_url = try std.Uri.parse(w.buffered());

            const start = w.buffered().len;
            w.writeAll(raw.etag_or_last_modified_or_hash.data) catch unreachable;
            const hash = w.buffered()[start..];


            return .{
                .feed_id = @fromBackingInt(raw.feed_id),
                .page_url = page_url,
                .etag_or_last_modified_or_hash = hash,
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

        return all(&self.sql_db, IconFailed, allocator, query, .{});
    }
    
    pub fn icon_update(self: *Self, curr_icon_id: IconRender.ID, icon: types.Icon) !void {
        assert(icon.data.len > 0);

        var buf_icon: [1024]u8 = undefined;
        const icon_url = try std.fmt.bufPrint(&buf_icon, "{f}", .{icon.url});
        const data_blob = sql.blob(icon.data);
        const query = 
        \\UPDATE icon SET
        \\  icon_url = ?,
        \\  icon_data = ?,
        \\  etag_or_last_modified_or_hash = ?
        \\WHERE icon_id = ?;
        ;

        const values = .{sql.text(icon_url), data_blob, sql.text(icon.etag_or_last_modified_or_hash), @backingInt(curr_icon_id)};
        try self.sql_db.exec(query, values);
    }

    pub fn icon_by_id(self: *Self, allocator: Allocator, id: IconRender.ID) !?types.IconRender {
        const query =
        \\SELECT icon_id, icon_url, icon_data, etag_or_last_modified_or_hash
        \\FROM icon WHERE icon_id = ?;
        ;

        if (try one(types.IconRender, &self.sql_db, allocator, query, .{@backingInt(id)})) |icon| {
            return icon;
        }

        return null;
    }
    
    pub fn icon_get_id(self: *Self, icon_url: []const u8) !IconRender.ID {
        assert(is_url_or_data(icon_url));
        const query = 
        \\select icon_id as val FROM icon
        \\WHERE icon_url = :url or icon_data = :url
        \\LIMIT 1;
        ;
        if (try one(u64, &self.sql_db, undefined, query, .{.url = sql.text(icon_url)})) |icon_id| {
            return @fromBackingInt(icon_id);
        }
        return .unassigned;
    }

    pub fn feed_icon_update(self: *Self, feed_id: Feed.ID, icon_id: ?IconRender.ID) !void {
        assert(feed_id != .unassigned);
        assert(icon_id != .unassigned);
        const query = 
        \\UPDATE feed SET
        \\  icon_id = ?
        \\WHERE feed_id = ?;
        ;

        try self.sql_db.exec(query, .{if (icon_id) |id| @backingInt(id) else null, @backingInt(feed_id)});
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
        try self.sql_db.exec(query, .{
            @backingInt(icon_failed.feed_id),
            if (icon_failed.last_msg) |msg| sql.text(msg) else null,
        });
    }

    pub fn icon_failed_remove(self: *Self, feed_id: Feed.ID) !void {
        assert(feed_id != .unassigned);
        const query =
            \\DELETE FROM icon_failed WHERE feed_id = ?;
        ;
        try self.sql_db.exec(query, .{@backingInt(feed_id)});
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

        try self.sql_db.exec(query, .{
            @backingInt(feed_id),
            sql.text(options.selector_container),
            if (options.selector_link) |val| sql.text(val) else null,
            if (options.selector_heading) |val| sql.text(val) else null,
            if (options.selector_date) |val| sql.text(val) else null,
            if (options.date_format) |val| sql.text(val) else null,
        });
    }

    pub fn html_selector_has(self: *Self, feed_id: Feed.ID) !bool {
        assert(feed_id != .unassigned);
        const query = "select exists(select 1 from html_selector where feed_id = ?) as val";
        if (try one(u32, &self.sql_db, undefined, query, .{@backingInt(feed_id)})) |val| {
            return val == 1;
        }
        return false;
    }

    pub fn html_selector_get(self: *Self, allocator: Allocator, feed_id: Feed.ID) !?parse.HtmlOptions {
        assert(feed_id != .unassigned);
        const query = 
        \\select 
        \\ container as selector_container,
        \\ link as selector_link,
        \\ heading as selector_heading,
        \\ date as selector_date,
        \\ date_format
        \\from html_selector
        \\where feed_id = :feed_id;
        ;

        if (try one(parse.HtmlOptions, &self.sql_db, allocator, query, .{ .feed_id = @backingInt(feed_id) })) |html_opts| {
            return html_opts;
        }
        return null;
    }

};

fn one(comptime T: type, db: *const sql.Database, allocator: Allocator, raw_query: []const u8, args: anytype) !?T {
    errdefer std.log.err("{?s}", .{db.errmsg()});
    const Params = @TypeOf(args);

    const info = @typeInfo(T);
    const is_struct = info == .@"struct";
    if (is_struct) {
        if (!@hasDecl(T, "Raw")) {
            @compileError(std.fmt.comptimePrint(
                "Struct '{}' must contain 'pub const Raw = struct {{..}}'",
                .{T})
            );
        }
        if (!@hasDecl(T, "from_raw")) {
            @compileError(std.fmt.comptimePrint(
                "Struct '{}' must contain 'pub fn from_raw(buf: []u8, raw: Raw) !@This() {{..}}'",
                .{T})
            );
        }
        if (!@hasDecl(T.Raw, "strings_len")) {
            @compileError(std.fmt.comptimePrint(
                "Struct '{}' must contain 'pub fn strings_len(raw: *const Raw) u64 {{..}}'",
                .{T.Raw})
            );
        }
    }
    const R = if (is_struct) T.Raw else struct {val: T};

    var stmt = try db.prepare(Params, R, raw_query);
    defer stmt.finalize();

    try stmt.bind(args);
    defer stmt.reset();

    if (stmt.step() catch |err| blk: {
        std.log.err("{?s} ({s})",.{db.errmsg(), @errorName(err)});
        std.log.err("query: |{s}|",.{raw_query});
        break :blk null;
    }) |row| {
        if (is_struct) {
            const buf_strings = try allocator.alloc(u8, row.strings_len());
            return try T.from_raw(buf_strings, row);
        }
        return row.val;
    }
    return null;
}

fn all(db: *const sql.Database, comptime T: type, allocator: Allocator, raw_query: []const u8, args: anytype) ![]const T {
    var res = try std.array_list.Managed(T).initCapacity(allocator, 10);
    errdefer res.deinit();

    const info = @typeInfo(T);
    const is_struct = info == .@"struct";
    const is_slice_u8 = switch(info) {
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) true else false,
        else => false,
    };
    const has_raw = is_struct and @hasDecl(T, "Raw") and @hasDecl(T, "from_raw") and @hasDecl(T.Raw, "strings_len") ;
    const R = blk: {
        if (is_struct) {
            if (has_raw) {
                break :blk T.Raw;
            }
            break :blk T;
        }
        break :blk struct {val: if (is_slice_u8) sql.Text else T};
    };

    var stmt = try db.prepare(@TypeOf(args), R, raw_query);
    defer stmt.finalize();

    try stmt.bind(args);
    defer stmt.reset();

    while (try stmt.step()) |row| {
        const val = blk: {
            if (is_struct) {
                if (has_raw) {
                    const buf_strings = try allocator.alloc(u8, T.Raw.strings_len(&row));
                    break :blk try T.from_raw(buf_strings, row);
                }
                break :blk row;
            }
            if (is_slice_u8) {
                break :blk try allocator.dupe(u8, row.val.data);
            }
            break :blk row.val;
        };
        try res.append(val);
    }

    return res.toOwnedSlice();
}

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
    ,
    \\CREATE TRIGGER IF NOT EXISTS feed_request_failed_insert_trigger
    \\   AFTER INSERT ON feed_request_failed
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'feed_request_failed';
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS feed_request_failed_delete_trigger
    \\   AFTER DELETE ON feed_request_failed
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'feed_request_failed';
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS rate_limit_insert_trigger
    \\   AFTER INSERT ON rate_limit
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'rate_limit';
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS rate_limit_insert_trigger
    \\   AFTER UPDATE ON rate_limit
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'rate_limit';
    \\END;
    ,
    \\CREATE TRIGGER IF NOT EXISTS rate_limit_delete_trigger
    \\   AFTER DELETE ON rate_limit
    \\BEGIN
    \\  update table_last_update set last_update_timestamp = strftime('%s', 'now')
    \\  where table_name = 'rate_limit';
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
        const count = try one(u64, &storage.sql_db, undefined, "select count(*) as val from feed", .{});
        try std.testing.expectEqual(1, count.?);
    }

    {
        const count = try one(u64, &storage.sql_db, undefined, "select count(*) as val from item", .{});
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
    var storage = try Storage.init(null);
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
        const value1 = try storage.getLatestFeedItemsWithFeedId(arena.allocator(), feed.feed_id, .{});
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
        try storage.icon_update(icon_id, icon);

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
        try storage.request_failed_add(feed.feed_id, "test failed 1");
        try storage.request_failed_add(feed.feed_id, "test failed 2");
        const failed_requests = try storage.request_failed_slice(arena.allocator(), feed.feed_id);
        try std.testing.expectEqual(2, failed_requests.len);

        const failed_requests_all = try storage.request_failed_all(arena.allocator());
        try std.testing.expectEqual(2, failed_requests_all.len);

        const request_failed_feeds = try storage.request_failed_feeds(arena.allocator());
        try std.testing.expectEqual(1, request_failed_feeds.len);

        try storage.request_failed_remove(feed.feed_id);

        const failed_ids = try storage.request_failed_ids(arena.allocator());
        try std.testing.expectEqual(0, failed_ids.len);
    }

    { // test rate limits
        const next_ts = try storage.next_update_timestamp();
        try std.testing.expect(next_ts.? > 0);

	const rate_utc = 1;
        try storage.rate_limit_add(feed.feed_id, rate_utc);
        const count = try one(u64, &storage.sql_db, undefined, "select count(*) as val from rate_limit", .{});
        try std.testing.expectEqual(1, count.?);

        const next_rate_ts = try storage.next_update_timestamp();
        try std.testing.expectEqual(rate_utc, next_rate_ts.?);

        try storage.rate_limit_remove(feed.feed_id);
        const count_empty = try one(u64, &storage.sql_db, undefined, "select count(*) as val from rate_limit", .{});
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
        const all_tags = try storage.tags_all(arena.allocator());
        try std.testing.expectEqual(add_tags.len - 1, all_tags.len);

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
            const count = try one(u64, &storage.sql_db, undefined, "select count(*) as val from feed", .{});
            try std.testing.expectEqual(0, count.?);
        }

        {
            const count = try one(u64, &storage.sql_db, undefined, "select count(*) as val from item", .{});
            try std.testing.expectEqual(0, count.?);
        }
    }
}
