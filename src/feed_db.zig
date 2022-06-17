const std = @import("std");
const Allocator = std.mem.Allocator;
const sql = @import("sqlite");
const db = @import("db.zig");
const fs = std.fs;
const fmt = std.fmt;
const print = std.debug.print;
const log = std.log;
const http = @import("http.zig");
const mem = std.mem;
const shame = @import("shame.zig");
const time = std.time;
const parse = @import("parse.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const ArrayList = std.ArrayList;
const Table = @import("queries.zig").Table;
const f = @import("feed.zig");
const Feed = f.Feed;
const curl = @import("curl_extend.zig");

// TODO: Mabye consolidate Storage (feed_db.zig) and Db (db.zig)
// Storage would be specific functions. Db would be utility/helper/wrapper functions

pub const g = struct {
    pub var max_items_per_feed: u16 = 10;
    pub const tag_untagged = "untagged";
};

pub const Storage = struct {
    const Self = @This();
    db: db.Db,
    allocator: Allocator,

    pub fn init(allocator: Allocator, location: ?[:0]const u8) !Self {
        return Self{ .db = try db.Db.init(allocator, location), .allocator = allocator };
    }

    pub fn addNewFeed(self: *Self, feed: Feed, feed_update: f.FeedUpdate, tags: [][]const u8) !u64 {
        std.debug.assert(feed.location.len != 0);
        var savepoint = try self.db.sql_db.savepoint("addNewFeed");
        defer savepoint.rollback();
        const query = "select id as feed_id, updated_timestamp from feed where location = ? limit 1;";
        var feed_id: u64 = 0;
        if (try self.db.one(Storage.CurrentData, query, .{feed.location})) |row| {
            try self.updateUrlFeed(.{
                .current = row,
                .headers = feed_update,
                .feed = feed,
            }, .{ .force = true });
            try self.addTags(row.feed_id, tags);
            feed_id = row.feed_id;
        } else {
            feed_id = try self.insertFeed(feed, feed.location);
            try self.addFeedUrl(feed_id, feed_update);
            try self.addItems(feed_id, feed.items);
            try self.addTags(feed_id, tags);
        }
        savepoint.commit();
        return feed_id;
    }

    pub fn insertFeed(self: *Self, feed: Feed, location: []const u8) !u64 {
        const query =
            \\INSERT INTO feed (title, location, link, updated_raw, updated_timestamp)
            \\VALUES (
            \\  ?{[]const u8},
            \\  ?{[]const u8},
            \\  ?,
            \\  ?,
            \\  ?
            \\) ON CONFLICT(location) DO UPDATE SET
            \\   title = excluded.title,
            \\   link = excluded.link,
            \\   updated_raw = excluded.updated_raw,
            \\   updated_timestamp = excluded.updated_timestamp
            \\WHERE updated_timestamp != excluded.updated_timestamp;
            \\RETURNING id;
        ;
        const args = .{ feed.title, location, feed.link, feed.updated_raw, feed.updated_timestamp };
        // Make sure function returns id.
        // 'query' returns id only if insert or update is made. If update doesn't get pass
        // where condition no id is returned.
        const id = (try self.db.one(u64, query, args)) orelse
            (try self.db.one(u64, "select id from feed where location == ?{[]const u8} limit 1;", .{location}));
        return id orelse error.NoReturnId;
    }

    pub fn deleteFeed(self: *Self, id: u64) !void {
        try self.db.exec("DELETE FROM feed WHERE id = ?", .{id});
    }

    pub fn addFeedUrl(self: *Self, feed_id: u64, headers: f.FeedUpdate) !void {
        const query =
            \\INSERT INTO feed_update_http
            \\  (feed_id, cache_control_max_age, expires_utc, last_modified_utc, etag)
            \\VALUES (
            \\  ?{u64},
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?
            \\)
            \\ ON CONFLICT(feed_id) DO UPDATE SET
            \\  cache_control_max_age = excluded.cache_control_max_age,
            \\  expires_utc = excluded.expires_utc,
            \\  last_modified_utc = excluded.last_modified_utc,
            \\  etag = excluded.etag,
            \\  last_update = (strftime('%s', 'now'))
        ;
        try self.db.exec(query, .{
            feed_id, headers.cache_control_max_age, headers.expires_utc, headers.last_modified_utc, headers.etag,
        });
    }

    pub fn addFeedLocal(
        self: *Self,
        feed_id: u64,
        last_modified: i64,
    ) !void {
        const query =
            \\INSERT INTO feed_update_local
            \\  (feed_id, last_modified_timestamp)
            \\VALUES (
            \\  ?{u64},
            \\  ?{i64}
            \\)
            \\ON CONFLICT(feed_id) DO UPDATE SET
            \\  last_modified_timestamp = excluded.last_modified_timestamp,
            \\  last_update = (strftime('%s', 'now'))
        ;
        try self.db.exec(query, .{ feed_id, last_modified });
    }

    pub fn addItems(self: *Self, feed_id: u64, feed_items: []Feed.Item) !void {
        const items = feed_items[0..std.math.min(feed_items.len, g.max_items_per_feed)];
        // Modifies item order in memory. Don't use after this if order is important.
        std.mem.reverse(Feed.Item, items);
        const hasGuidOrLink = blk: {
            const hasGuid = blk_guid: {
                for (items) |item| {
                    if (item.id == null) break :blk_guid false;
                } else {
                    break :blk_guid true;
                }
            };

            const hasLink = blk_link: {
                for (items) |item| {
                    if (item.link == null) break :blk_link false;
                } else {
                    break :blk_link true;
                }
            };

            break :blk hasGuid or hasLink;
        };
        const insert_query =
            \\INSERT INTO item (feed_id, title, link, guid, pub_date, pub_date_utc)
            \\VALUES (
            \\  ?{u64},
            \\  ?{[]const u8},
            \\  ?, ?, ?, ?
            \\)
        ;
        if (hasGuidOrLink) {
            const conflict_update =
                \\ DO UPDATE SET
                \\  title = excluded.title,
                \\  pub_date = excluded.pub_date,
                \\  pub_date_utc = excluded.pub_date_utc,
                \\  modified_at = (strftime('%s', 'now'))
                \\WHERE
                \\  excluded.pub_date_utc != pub_date_utc
            ;
            const query = insert_query ++ "\nON CONFLICT(feed_id, guid) " ++ conflict_update ++ "\nON CONFLICT(feed_id, link)" ++ conflict_update ++ ";";

            for (items) |item| {
                try self.db.exec(query, .{
                    feed_id, item.title,       item.link,
                    item.id, item.updated_raw, item.updated_timestamp,
                });
            }
            const del_query =
                \\DELETE FROM item
                \\WHERE id IN
                \\    (SELECT id FROM item
                \\        WHERE feed_id = ?
                \\        ORDER BY id ASC
                \\        LIMIT (SELECT MAX(count(feed_id) - ?, 0) FROM item WHERE feed_id = ?)
                \\  )
            ;
            try self.db.exec(del_query, .{ feed_id, g.max_items_per_feed, feed_id });
        } else {
            const del_query = "DELETE FROM item WHERE feed_id = ?;";
            try self.db.exec(del_query, .{feed_id});
            const query =
                \\INSERT INTO item (feed_id, title, link, guid, pub_date, pub_date_utc)
                \\VALUES (
                \\  ?{u64},
                \\  ?{[]const u8},
                \\  ?, ?, ?, ?
                \\);
            ;
            for (items) |item| {
                try self.db.exec(query, .{
                    feed_id, item.title,       item.link,
                    item.id, item.updated_raw, item.updated_timestamp,
                });
            }
        }
    }

    pub fn addTags(self: *Self, id: u64, tags: [][]const u8) !void {
        if (tags.len == 0) return;
        const query =
            \\INSERT INTO feed_tag VALUES (?, ?)
            \\ON CONFLICT(feed_id, tag) DO NOTHING;
        ;
        for (tags) |tag| {
            try self.db.exec(query, .{ id, tag });
        }
        // Make sure there is no 'untagged' tag
        const del_query = comptime fmt.comptimePrint(
            "delete from feed_tag where feed_id = ? and tag = '{s}';",
            .{g.tag_untagged},
        );
        try self.db.exec(del_query, .{id});
    }

    pub const UpdateOptions = struct {
        force: bool = false,
    };

    pub fn updateAllFeeds(self: *Self, opts: UpdateOptions) !void {
        try self.updateUrlFeeds(opts);
        try self.updateLocalFeeds(self.allocator, opts);
        try self.cleanItems();
    }

    fn deallocFieldsLen(comptime T: type) u8 {
        const meta = std.meta;
        const fields = comptime meta.fields(T);
        comptime var result = 0;
        inline for (fields) |field| {
            const is_slice = field.field_type == []const u8 or field.field_type == ?[]const u8 or
                field.field_type == []u8 or field.field_type == ?[]u8;

            if (is_slice) result += 1;
        }
        return result;
    }

    const DeAllocField = struct { is_optional: bool, name: []const u8 };
    fn deallocFields(comptime T: type) [deallocFieldsLen(T)]DeAllocField {
        const meta = std.meta;
        const fields = comptime meta.fields(T);
        const len = comptime deallocFieldsLen(T);
        comptime var result: [len]DeAllocField = undefined;
        inline for (fields) |field, i| {
            const is_slice = field.field_type == []const u8 or field.field_type == ?[]const u8 or
                field.field_type == []u8 or field.field_type == ?[]u8;

            if (is_slice) {
                const is_optional = switch (@typeInfo(field.field_type)) {
                    .Pointer => false,
                    .Optional => true,
                    else => @compileError("Parsing UrlFeed struct failed."),
                };
                // Reverse fields' order
                result[len - 1 - i] = .{ .is_optional = is_optional, .name = field.name };
            }
        }
        return result;
    }

    pub fn updateUrlFeeds(self: *Self, opts: UpdateOptions) !void {
        if (!opts.force) {
            // Update every update_countdown value
            // (expires_utc / 1000) - convert into seconds
            const update_countdown_query =
                \\WITH const AS (SELECT strftime('%s', 'now') as current_utc)
                \\UPDATE feed_update_http SET update_countdown = COALESCE(
                \\  (last_update + cache_control_max_age) - const.current_utc,
                \\  (expires_utc / 1000) - const.current_utc,
                \\  (last_update + (update_interval * 60)) - const.current_utc
                \\) from const;
            ;
            try self.db.exec(update_countdown_query, .{});
        }
        const UrlFeed = struct {
            location: []const u8,
            feed_id: u64,
            etag: ?[]const u8 = null,
            updated_timestamp: ?i64 = null,
            last_modified_utc: ?i64 = null,
        };

        const base_query =
            \\SELECT
            \\  feed.location as location,
            \\  feed_id,
            \\  etag,
            \\  feed.updated_timestamp as updated_timestamp,
            \\  last_modified_utc
            \\FROM feed_update_http
            \\LEFT JOIN feed ON feed_update_http.feed_id = feed.id
        ;

        const query = if (opts.force) base_query else base_query ++ "\nWHERE update_countdown < 0;";
        var stmt = try self.db.sql_db.prepareDynamic(query);
        defer stmt.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var rows = try stmt.all(UrlFeed, arena.allocator(), .{}, .{});
        var headers = try ArrayList([]const u8).initCapacity(arena.allocator(), http.general_request_headers_curl.len + 2);
        headers.appendSliceAssumeCapacity(&http.general_request_headers_curl);
        var stack_fallback = std.heap.stackFallback(128, arena.allocator());
        for (rows) |row| {
            log.info("Updating: '{s}'", .{row.location});
            try headers.resize(http.general_request_headers_curl.len);
            var stack_alloc = stack_fallback.get();
            if (row.etag) |etag| {
                const header = try fmt.allocPrint(stack_alloc, "If-None-Match: {s}", .{etag});
                headers.appendAssumeCapacity(header);
            } else if (row.last_modified_utc) |last_modified_utc| {
                var buf: [32]u8 = undefined;
                const date_str = try @import("datetime").datetime.Datetime.formatHttpFromTimestamp(&buf, last_modified_utc);
                const header = try fmt.allocPrint(stack_alloc, "If-Modified-Since: {s}", .{date_str});
                headers.appendAssumeCapacity(header);
            }
            var resp = try http.resolveRequestCurl(&arena, row.location, .{ .headers = headers.items });
            defer resp.deinit();

            switch (resp.status_code) {
                200 => {},
                304 => {
                    // status code 304 might not contain 'Expires' header like status code '200'
                    const last_header = curl.getLastHeader(resp.headers_fifo.readableSlice(0));
                    if (curl.getHeaderValue(last_header, "expires:")) |value| {
                        const query_http_update =
                            \\UPDATE feed_update_http SET expires_utc = ? WHERE feed_id = ?;
                        ;
                        const expires_utc = try parse.Rss.pubDateToTimestamp(value);
                        try self.db.exec(query_http_update, .{ expires_utc, row.feed_id });
                    }
                    log.info("Skip updating feed {s}. Feed hasn't been modified/changed", .{row.location});
                    continue;
                },
                else => {
                    log.info("Skip updating feed {s}. Failed HTTP request code: {d} ", .{ row.location, resp.status_code });
                    continue;
                },
            }

            const last_header = curl.getLastHeader(resp.headers_fifo.readableSlice(0));
            const content_type_value = curl.getHeaderValue(last_header, "content-type:") orelse {
                log.info("Skip updating feed {s}. Found no Content-Type HTTP header", .{row.location});
                continue;
            };
            const content_type = http.ContentType.fromString(content_type_value);
            switch (content_type) {
                .html, .unknown => {
                    print(
                        "Failed to add url {s}. Don't handle mimetype {s}",
                        .{ row.location, content_type_value },
                    );
                },
                else => {},
            }

            const body = resp.body_fifo.readableSlice(0);
            const feed = try f.Feed.initParse(&arena, row.location, body, content_type);
            const feed_update = try f.FeedUpdate.fromHeadersCurl(last_header);
            var savepoint = try self.db.sql_db.savepoint("updateUrlFeeds");
            defer savepoint.rollback();
            const update_data = UpdateData{
                .current = .{ .feed_id = row.feed_id, .updated_timestamp = row.updated_timestamp },
                .headers = feed_update,
                .feed = feed,
            };
            try self.updateUrlFeed(update_data, opts);
            savepoint.commit();
            log.info("Updated: '{s}'", .{row.location});
        }
    }

    pub const CurrentData = struct { feed_id: u64, updated_timestamp: ?i64 };
    const UpdateData = struct {
        current: CurrentData,
        feed: Feed,
        headers: f.FeedUpdate,
    };
    pub fn updateUrlFeed(self: *Self, data: UpdateData, opts: UpdateOptions) !void {
        const query_http_update =
            \\UPDATE feed_update_http SET
            \\  cache_control_max_age = ?,
            \\  expires_utc = ?,
            \\  last_modified_utc = ?,
            \\  etag = ?,
            \\  last_update = (strftime('%s', 'now'))
            \\WHERE feed_id = ?
        ;
        try self.db.exec(query_http_update, .{
            data.headers.cache_control_max_age,
            data.headers.expires_utc,
            data.headers.last_modified_utc,
            data.headers.etag,
            // where
            data.current.feed_id,
        });

        if (!opts.force) {
            if (data.feed.updated_timestamp != null and data.current.updated_timestamp != null and
                data.feed.updated_timestamp.? == data.current.updated_timestamp.?)
            {
                log.info("\tSkipping update: Feed publish date hasn't changed", .{});
                return;
            }
        }

        try self.db.exec(Table.feed.update_where_id, .{
            data.feed.link, data.feed.updated_raw, data.feed.updated_timestamp, data.current.feed_id,
        });

        try self.addItems(data.current.feed_id, data.feed.items);
    }

    pub fn updateLocalFeeds(self: *Self, opts: UpdateOptions) !void {
        const LocalFeed = struct {
            location: []const u8,
            feed_id: u64,
            feed_updated_timestamp: ?i64,
            last_modified_timestamp: ?i64,

            pub fn deinit(row: @This(), allocator: Allocator) void {
                // If LocalFeed gets more allocatable fields use deallocFields()
                allocator.free(row.location);
            }
        };

        var contents = ArrayList(u8).init(self.allocator);
        defer contents.deinit();

        const query_update_local =
            \\UPDATE feed_update_local SET
            \\  last_modified_timestamp = ?,
            \\  last_update = (strftime('%s', 'now'))
            \\WHERE feed_id = ?
        ;

        const query_all =
            \\SELECT
            \\  feed.location as location,
            \\  feed_id,
            \\  feed.updated_timestamp as feed_update_timestamp,
            \\  last_modified_timestamp
            \\FROM feed_update_local
            \\LEFT JOIN feed ON feed_update_local.feed_id = feed.id;
        ;

        var stack_fallback = std.heap.stackFallback(256, self.allocator);
        const stack_allocator = stack_fallback.get();
        var stmt = try self.db.sql_db.prepare(query_all);
        defer stmt.deinit();
        var iter = try stmt.iterator(LocalFeed, .{});
        while (try iter.nextAlloc(stack_allocator, .{})) |row| {
            defer row.deinit(stack_allocator);
            log.info("Updating: '{s}'", .{row.location});
            const file = try std.fs.openFileAbsolute(row.location, .{});
            defer file.close();
            var file_stat = try file.stat();
            const mtime_sec = @intCast(i64, @divFloor(file_stat.mtime, time.ns_per_s));
            if (!opts.force) {
                if (row.last_modified_timestamp) |last_modified| {
                    if (last_modified == mtime_sec) {
                        log.info("\tSkipping update: File hasn't been modified", .{});
                        continue;
                    }
                }
            }

            try contents.resize(0);
            try contents.ensureTotalCapacity(file_stat.size);
            try file.reader().readAllArrayList(&contents, file_stat.size);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            var rss_feed = try parse.parse(&arena, contents.items);

            var savepoint = try self.db.sql_db.savepoint("updateLocalFeeds");
            defer savepoint.rollback();
            try self.db.exec(query_update_local, .{ mtime_sec, row.feed_id });

            if (!opts.force) {
                if (rss_feed.updated_timestamp != null and row.feed_updated_timestamp != null and
                    rss_feed.updated_timestamp.? == row.feed_updated_timestamp.?)
                {
                    savepoint.commit();
                    log.info("\tSkipping update: Feed updated/pubDate hasn't changed", .{});
                    continue;
                }
            }

            try self.db.exec(Table.feed.update_where_id, .{
                rss_feed.link, rss_feed.updated_raw, rss_feed.updated_timestamp, row.feed_id,
            });

            try self.addItems(row.feed_id, rss_feed.items);
            savepoint.commit();
            log.info("Updated: '{s}'", .{row.location});
        }
    }

    pub fn cleanItemsByFeedId(self: *Self, feed_id: u64) !void {
        const query =
            \\DELETE FROM item
            \\WHERE id IN
            \\    (SELECT id FROM item
            \\        WHERE feed_id = ?
            \\        ORDER BY id ASC
            \\        LIMIT (SELECT MAX(count(feed_id) - ?, 0) FROM item WHERE feed_id = ?)
            \\  )
        ;
        try db.delete(&self.db, query, .{ feed_id, g.max_items_per_feed, feed_id });
    }

    pub fn cleanItems(self: *Self) !void {
        const query =
            \\SELECT
            \\  feed_id, count(feed_id) as count
            \\FROM item
            \\GROUP BY feed_id
            \\HAVING count(feed_id) > ?{u16}
        ;

        const DbResult = struct { feed_id: u64, count: usize };

        const results = try self.db.selectAll(DbResult, query, .{g.max_items_per_feed});

        const del_query =
            \\DELETE FROM item
            \\WHERE id IN (SELECT id
            \\  FROM item
            \\  WHERE feed_id = ?
            \\  ORDER BY pub_date_utc ASC, modified_at ASC LIMIT ?
            \\)
        ;
        for (results) |r| {
            const del_count = r.count - g.max_items_per_feed;
            if (del_count > 0) {
                try self.db.exec(del_query, .{ r.feed_id, del_count });
            }
        }
    }

    pub const SearchResult = struct {
        location: []const u8,
        title: []const u8,
        link: ?[]const u8,
        id: u64,
    };

    pub fn search(self: *Self, allocator: Allocator, terms: [][]const u8) ![]SearchResult {
        const query_start = "SELECT location, title, link, id FROM feed WHERE ";
        const like_query = "location LIKE '%{s}%' OR link LIKE '%{s}%' OR title LIKE '%{s}%'";
        const query_or = " OR ";
        var total_cap = blk: {
            const or_len = (terms.len - 1) * query_or.len;
            const like_len = terms.len * (like_query.len - 9); // remove placeholders '{s}'
            break :blk query_start.len + or_len + like_len;
        };
        for (terms) |term| total_cap += term.len * 3;

        var query_arr = try ArrayList(u8).initCapacity(allocator, total_cap);
        defer query_arr.deinit();
        const writer = query_arr.writer();
        var buf: [256]u8 = undefined;
        {
            writer.writeAll(query_start) catch unreachable;
            const term = terms[0];
            // Guard against sql injection
            // 'term' will be cut if longer than 'buf'
            const safe_term = sql.c.sqlite3_snprintf(buf.len, &buf, "%q", term.ptr);
            if (mem.len(safe_term) > term.len) {
                total_cap += mem.len(safe_term) - term.len;
                try query_arr.ensureTotalCapacity(total_cap);
            }
            writer.print(like_query, .{ safe_term, safe_term, safe_term }) catch unreachable;
        }
        for (terms[1..]) |term| {
            // Guard against sql injection
            // 'term' will be cut if longer than 'buf'
            const safe_term = sql.c.sqlite3_snprintf(buf.len, &buf, "%q", term.ptr);
            if (mem.len(safe_term) > term.len) {
                total_cap += mem.len(safe_term) - term.len;
                try query_arr.ensureTotalCapacity(total_cap);
            }
            writer.writeAll(query_or) catch unreachable;
            writer.print(like_query, .{ safe_term, safe_term, safe_term }) catch unreachable;
        }

        var stmt = self.db.sql_db.prepareDynamic(query_arr.items) catch |err| {
            log.err("SQL_ERROR: {s}\nFailed query:\n{s}", .{ self.db.sql_db.getDetailedError().message, query_arr.items });
            return err;
        };
        defer stmt.deinit();

        const results = stmt.all(SearchResult, allocator, .{}, .{}) catch |err| {
            log.err("SQL_ERROR: {s}\n", .{self.db.sql_db.getDetailedError().message});
            return err;
        };
        return results;
    }

    pub fn addTagsByLocation(self: *Self, tags: [][]const u8, location: []const u8) !void {
        const feed_id = (try self.db.one(u64, "select id from feed where location = ?;", .{location})) orelse {
            log.err("Failed to find feed with location '{s}'", .{location});
            return;
        };
        try self.addTags(feed_id, tags);
    }

    pub fn addTagsById(self: *Self, tags: [][]const u8, feed_id: u64) !void {
        _ = (try self.db.one(void, "select id from feed where id = ?;", .{feed_id})) orelse {
            log.err("Failed to find feed with id '{d}'", .{feed_id});
            return;
        };
        try self.addTags(feed_id, tags);
    }

    pub fn removeTagsByLocation(self: *Self, tags: [][]const u8, location: []const u8) !void {
        const feed_id = (try self.db.one(u64, "SELECT id FROM feed WHERE location = ?;", .{location})) orelse {
            log.warn("Couldn't find location '{s}'", .{location});
            return;
        };
        try self.removeTagsById(tags, feed_id);
    }

    pub fn removeTagsById(self: *Self, tags: [][]const u8, id: u64) !void {
        const query = "DELETE FROM feed_tag WHERE tag = ? AND feed_id = ?;";
        for (tags) |tag| {
            try self.db.exec(query, .{ tag, id });
        }
        try self.untaggedCheck(id);
    }

    pub fn untaggedCheck(self: *Self, feed_id: u64) !void {
        const has_tags =
            (try self.db.one(void, "SELECT 1 FROM feed_tag WHERE feed_id = ? LIMIT 1", .{feed_id})) != null;

        if (!has_tags) {
            const insert_query = comptime fmt.comptimePrint("insert into feed_tag (feed_id, tag) values (?, '{s}')", .{g.tag_untagged});
            try self.db.exec(insert_query, .{feed_id});
        }
    }

    pub fn removeTags(self: *Self, tags: [][]const u8) !void {
        const query = "DELETE FROM feed_tag WHERE tag = ? RETURNING feed_id;";
        for (tags) |tag| {
            const feed_ids = try self.db.selectAll(u64, query, .{tag});
            for (feed_ids) |feed_id| {
                try self.untaggedCheck(feed_id);
            }
        }
    }

    pub const TagCount = struct { name: []const u8, count: u32 };
    pub fn getAllTags(self: *Self) ![]TagCount {
        const query = "SELECT tag as name, count(tag) FROM feed_tag GROUP BY tag ORDER BY tag ASC;";
        return try self.db.selectAll(TagCount, query, .{});
    }

    pub const FeedData = struct {
        title: []const u8,
        location: []const u8,
        link: ?[]const u8,
    };
    pub fn getFeedById(self: *Self, id: u64) !?FeedData {
        return try self.db.oneAlloc(Feed, "select title, location, link from feed where id = ? limit 1;", .{id});
    }

    pub const RecentFeed = struct {
        id: u64,
        updated_timestamp: ?i64,
        title: []const u8,
        link: ?[]const u8,
    };
    pub fn getRecentlyUpdatedFeeds(self: *Self) ![]RecentFeed {
        const query =
            \\SELECT
            \\  id
            \\, max(updated_timestamp, item.pub_date_utc) AS updated_timestamp
            \\, title
            \\, link
            \\FROM feed
            \\LEFT JOIN
            \\  (SELECT feed_id, max(pub_date_utc) as pub_date_utc FROM item GROUP BY feed_id) item
            \\ON item.feed_id = feed.id
            \\ORDER BY updated_timestamp DESC;
        ;
        return try self.db.selectAll(RecentFeed, query, .{});
    }

    pub fn getRecentlyUpdatedFeedsByTags(self: *Self, tags: [][]const u8) ![]RecentFeed {
        const query_start =
            \\SELECT
            \\  id
            \\, max(updated_timestamp, item.pub_date_utc) AS updated_timestamp
            \\, title
            \\, link
            \\FROM feed
            \\LEFT JOIN
            \\  (SELECT feed_id, max(pub_date_utc) as pub_date_utc FROM item GROUP BY feed_id) item
            \\ON item.feed_id = feed.id
            \\WHERE item.feed_id in (SELECT DISTINCT feed_id FROM feed_tag WHERE tag IN (
        ;
        const query_end =
            \\))
            \\ORDER BY updated_timestamp DESC;
        ;
        var total_cap = query_start.len + query_end.len + tags[0].len + 2; // 2 - two quotes
        for (tags[1..]) |tag| total_cap += tag.len + 3; // 3 - two quotes + comma
        var query_arr = try ArrayList(u8).initCapacity(self.allocator, total_cap);
        defer query_arr.deinit();
        const writer = query_arr.writer();
        writer.writeAll(query_start) catch unreachable;
        var buf: [256]u8 = undefined;
        {
            const tag = tags[0];
            const tag_cstr = try self.allocator.dupeZ(u8, tag);
            defer self.allocator.free(tag_cstr);
            print("{s}", .{tag});
            // Guard against sql injection
            // 'tag' will be cut if longer than 'buf'
            const safe_term = sql.c.sqlite3_snprintf(buf.len, &buf, "%Q", tag_cstr.ptr);
            // total_cap takes into account adding quotes to both ends
            const tag_len_with_quotes = tag.len + 2;
            if (mem.len(safe_term) > tag_len_with_quotes) {
                total_cap += mem.len(safe_term) - tag_len_with_quotes;
                try query_arr.ensureTotalCapacity(total_cap);
            }
            writer.writeAll(mem.span(safe_term)) catch unreachable;
        }
        for (tags[1..]) |tag| {
            // Guard against sql injection
            // 'tag' will be cut if longer than 'buf'
            const tag_cstr = try self.allocator.dupeZ(u8, tag);
            defer self.allocator.free(tag_cstr);
            const safe_term = sql.c.sqlite3_snprintf(buf.len, &buf, "%Q", tag_cstr.ptr);
            // total_cap takes into account adding quotes to both ends
            const tag_len_with_quotes = tag.len + 2;
            if (mem.len(safe_term) > tag_len_with_quotes) {
                total_cap += mem.len(safe_term) - tag_len_with_quotes;
                try query_arr.ensureTotalCapacity(total_cap);
            }
            writer.writeAll(",") catch unreachable;
            writer.writeAll(mem.span(safe_term)) catch unreachable;
        }
        writer.writeAll(query_end) catch unreachable;
        var stmt = self.db.sql_db.prepareDynamic(query_arr.items) catch |err| {
            log.err("SQL_ERROR: {s}\nFailed query:\n{s}", .{ self.db.sql_db.getDetailedError().message, query_arr.items });
            return err;
        };
        defer stmt.deinit();

        const results = stmt.all(RecentFeed, self.allocator, .{}, .{}) catch |err| {
            log.err("SQL_ERROR: {s}\n", .{self.db.sql_db.getDetailedError().message});
            return err;
        };
        return results;
    }

    const Item = struct {
        title: []const u8,
        link: ?[]const u8,
        pub_date_utc: ?i64,
    };
    pub fn getItems(self: *Self, id: u64) ![]Item {
        const query =
            \\SELECT title, link, pub_date_utc FROM item WHERE feed_id = ?{u64} ORDER BY id DESC;
        ;
        return try self.db.selectAll(Item, query, .{id});
    }

    pub fn untaggedFeedsCount(self: *Self) !u32 {
        const query =
            \\SELECT count(id) from feed where id not in (SELECT DISTINCT feed_id FROM feed_tag);
        ;
        return (try self.db.one(u32, query, .{})).?;
    }
};

fn equalNullString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return mem.eql(u8, a.?, b.?);
}

test "add, delete feed" {
    // std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const location = "https://lobste.rs/";
    const contents = @embedFile("../test/rss2.xml");
    var feed_db = try Storage.init(allocator, null);
    var feed = try parse.parse(&arena, contents);

    var savepoint = try feed_db.db.sql_db.savepoint("test_net");
    defer savepoint.rollback();
    const id = try feed_db.insertFeed(feed, location);
    try feed_db.addFeedUrl(id, .{});

    const ItemsResult = struct { title: []const u8 };
    const all_items_query = "select title from item order by id DESC";

    // No items yet
    const saved_items = try feed_db.db.selectAll(ItemsResult, all_items_query, .{});
    try expect(saved_items.len == 0);

    // Add some items
    const start_index = 3;
    try expect(start_index < feed.items.len);
    const items_src = feed.items[3..];
    var tmp_items = try allocator.alloc(Feed.Item, items_src.len);
    std.mem.copy(Feed.Item, tmp_items, items_src);
    try feed_db.addItems(id, tmp_items);
    {
        const items = try feed_db.db.selectAll(ItemsResult, all_items_query, .{});
        try expectEqual(items.len, items_src.len);
        for (items) |item, i| {
            try std.testing.expectEqualStrings(items_src[i].title, item.title);
        }
    }

    // delete feed
    try feed_db.deleteFeed(id);
    {
        const count_item = try feed_db.db.one(u32, "select count(id) from item", .{});
        try expect(count_item.? == 0);
        const count_feed = try feed_db.db.one(u32, "select count(id) from feed", .{});
        try expect(count_feed.? == 0);
        const count_http = try feed_db.db.one(u32, "select count(feed_id) from feed_update_http", .{});
        try expect(count_http.? == 0);
    }
    savepoint.commit();
}

test "Storage local" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var feed_db = try Storage.init(allocator, null);

    // const abs_path = "/media/hdd/code/feedgaze/test/sample-rss-2.xml";
    const rel_path = "test/rss2.xml";
    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    const abs_path = try fs.cwd().realpath(rel_path, &path_buf);
    const contents = try shame.getFileContents(allocator, abs_path);
    const file = try fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const stat = try file.stat();
    const mtime_sec = @intCast(i64, @divFloor(stat.mtime, time.ns_per_s));

    var feed = try parse.parse(&arena, contents);

    var savepoint = try feed_db.db.sql_db.savepoint("test_local");
    defer savepoint.rollback();
    const id = try feed_db.insertFeed(feed, abs_path);
    try feed_db.addFeedLocal(id, mtime_sec);
    const last_items = feed.items[3..];
    var tmp_items = try allocator.alloc(Feed.Item, last_items.len);
    std.mem.copy(Feed.Item, tmp_items, last_items);
    try feed_db.addItems(id, tmp_items);
    try feed_db.addTags(id, "local,local,not-net");

    const LocalItem = struct { title: []const u8 };
    const all_items_query = "select title from item order by id DESC";

    // Feed local
    {
        const items = try feed_db.db.selectAll(LocalItem, all_items_query, .{});
        try expectEqual(items.len, last_items.len);
        for (items) |item, i| {
            try expectEqualStrings(item.title, last_items[i].title);
        }

        const tags = try feed_db.db.selectAll(struct { tag: []const u8 }, "select tag from feed_tag", .{});
        try expectEqual(@as(usize, 2), tags.len);
        try expectEqualStrings(tags[0].tag, "local");
        try expectEqualStrings(tags[1].tag, "not-net");
    }

    // Remove one tag
    {
        var tag_local = "local";
        var rm_tags = &[_][]const u8{tag_local};
        try feed_db.removeTags(rm_tags);
        const tags = try feed_db.db.selectAll(struct { tag: []const u8 }, "select tag from feed_tag", .{});
        try expectEqual(@as(usize, 1), tags.len);
        try expectEqualStrings(tags[0].tag, "not-net");
    }

    const LocalUpdateResult = struct { feed_id: u64, update_interval: u32, last_update: i64, last_modified_timestamp: i64 };
    const local_query = "select feed_id, update_interval, last_update, last_modified_timestamp from feed_update_local";

    // Local feed update
    {
        const count = try feed_db.db.one(u32, "select count(*) from feed_update_local", .{});
        try expect(count.? == 1);
        const feed_dbfeeds = try feed_db.db.one(LocalUpdateResult, local_query, .{});
        const first = feed_dbfeeds.?;
        try expect(first.feed_id == 1);
        try expect(first.update_interval == @import("queries.zig").update_interval);
        const current_time = std.time.timestamp();
        try expect(first.last_update <= current_time);
        try expect(first.last_modified_timestamp == mtime_sec);
    }

    try feed_db.updateLocalFeeds(.{ .force = true });

    // Items
    {
        const items = try feed_db.db.selectAll(LocalItem, all_items_query, .{});
        try expect(items.len == feed.items.len);
        for (items) |item, i| {
            const f_item = feed.items[i];
            try expectEqualStrings(item.title, f_item.title);
        }
    }

    {
        const feed_dbfeeds = try feed_db.db.one(LocalUpdateResult, local_query, .{});
        const first = feed_dbfeeds.?;
        try expect(first.feed_id == 1);
        const current_time = std.time.timestamp();
        try expect(first.last_update <= current_time);
    }
    try feed_db.cleanItems();

    // Delete feed
    {
        try feed_db.deleteFeed(id);
        const count_item = try feed_db.db.one(u32, "select count(id) from item", .{});
        try expect(count_item.? == 0);
        const count_feed = try feed_db.db.one(u32, "select count(id) from feed", .{});
        try expect(count_feed.? == 0);
        const count_http = try feed_db.db.one(u32, "select count(feed_id) from feed_update_local", .{});
        try expect(count_http.? == 0);
    }
    savepoint.commit();
}

test "different urls, same feed items" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = try Storage.init(allocator, null);

    const location1 = "location1";
    const items_base = [_]Feed.Item{
        .{ .title = "title1", .id = "same_id1" },
        .{ .title = "title2", .id = "same_id2" },
    };
    const parsed_feed = Feed{
        .title = "Same stuff",
    };
    const id1 = try storage.insertFeed(parsed_feed, location1);
    var items: [items_base.len]Feed.Item = undefined;
    mem.copy(Feed.Item, &items, &items_base);
    try storage.addItems(id1, &items);
    const location2 = "location2";
    const id2 = try storage.insertFeed(parsed_feed, location2);
    try storage.addItems(id2, &items);

    const feed_count_query = "select count(id) from feed";
    const item_feed_count_query = "select count(DISTINCT feed_id) from item";
    const feed_count = try storage.db.one(u32, feed_count_query, .{});
    const item_feed_count = try storage.db.one(u32, item_feed_count_query, .{});
    try expectEqual(feed_count.?, item_feed_count.?);
    const item_count_query = "select count(id) from item";
    const item_count = try storage.db.one(u32, item_count_query, .{});
    try expectEqual(items.len * 2, item_count.?);
}

// Requires running test server - cmd: just test-server
test "updateUrlFeeds: check that only neccessary url feeds are updated" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = try Storage.init(allocator, null);

    {
        const location1 = "http://localhost:8080/atom.atom";
        const parsed_feed = Feed{ .title = "Title: location 1" };
        const id1 = try storage.insertFeed(parsed_feed, location1);
        const feed_update = f.FeedUpdate{
            .expires_utc = std.math.maxInt(i64), // no update
        };
        try storage.addFeedUrl(id1, feed_update);
    }

    {
        const location1 = "http://localhost:8080/atom.xml";
        const parsed_feed = Feed{ .title = "Title: location 2" };
        const id1 = try storage.insertFeed(parsed_feed, location1);
        const feed_update = f.FeedUpdate{
            .cache_control_max_age = 300,
        };
        try storage.addFeedUrl(id1, feed_update);
        // will update feed
        const query = "update feed_update_http set last_update = ? where feed_id = ?;";
        try storage.db.exec(query, .{ std.math.maxInt(u32), id1 });
    }

    {
        const location1 = "http://localhost:8080/rss2.rss";
        const parsed_feed = Feed{ .title = "Title: location 3" };
        const id1 = try storage.insertFeed(parsed_feed, location1);
        const feed_update = f.FeedUpdate{};
        try storage.addFeedUrl(id1, feed_update);
        // will update feed
        const query = "update feed_update_http set last_update = ? where feed_id = ?;";
        try storage.db.exec(query, .{ std.math.maxInt(u32), id1 });
    }

    try storage.updateUrlFeeds(Storage.UpdateOptions{});
    const query_last_update = "select last_update from feed_update_http";
    {
        const last_updates = try storage.db.selectAll(i64, query_last_update, .{});
        for (last_updates) |last_update| try expect(last_update < std.math.maxInt(u32));
    }

    try storage.db.exec("update feed_update_http set last_update = 0;", .{});
    try storage.updateUrlFeeds(Storage.UpdateOptions{ .force = true });

    {
        const last_updates = try storage.db.selectAll(i64, query_last_update, .{});
        for (last_updates) |last_update| try expect(last_update > 0);
    }
}
