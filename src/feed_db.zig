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

// TODO: Mabye consolidate Storage (feed_db.zig) and Db (db.zig)
// Storage would be specific functions. Db would be utility/helper/wrapper functions

pub const g = struct {
    pub var max_items_per_feed: u16 = 10;
};

pub const Storage = struct {
    const Self = @This();
    db: db.Db,
    allocator: Allocator,

    pub fn init(allocator: Allocator, location: ?[:0]const u8) !Self {
        return Self{ .db = try db.Db.init(allocator, location), .allocator = allocator };
    }

    pub fn addFeed(self: *Self, feed: parse.Feed, location: []const u8) !u64 {
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

    pub fn addFeedUrl(self: *Self, feed_id: u64, headers: http.RespHeaders) !void {
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

    pub fn addItems(self: *Self, feed_id: u64, feed_items: []parse.Feed.Item) !void {
        const items = feed_items[0..std.math.min(feed_items.len, g.max_items_per_feed)];
        // Modifies item order in memory. Don't use after this if order is important.
        std.mem.reverse(parse.Feed.Item, items);
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

    pub fn addTags(self: *Self, id: u64, tags: []const u8) !void {
        if (tags.len == 0) return;
        const query =
            \\INSERT INTO feed_tag VALUES (?, ?)
            \\ON CONFLICT(feed_id, tag) DO NOTHING;
        ;
        var iter = mem.split(u8, tags, ",");
        while (iter.next()) |tag| {
            try self.db.exec(query, .{ id, tag });
        }
    }

    pub const UpdateOptions = struct {
        force: bool = false,
        // For testing purposes
        resolveUrl: @TypeOf(http.resolveRequest) = http.resolveRequest,
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
            const update_countdown_query =
                \\WITH const AS (SELECT strftime('%s', 'now') as current_utc)
                \\UPDATE feed_update_http SET update_countdown = COALESCE(
                \\  const.current_utc - last_update + cache_control_max_age,
                \\  expires_utc - const.current_utc,
                \\  const.current_utc - last_update + update_interval
                \\) from const;
            ;
            try self.db.exec(update_countdown_query, .{});
        }
        const UrlFeed = struct {
            location: []const u8,
            etag: ?[]const u8,
            feed_id: u64,
            updated_timestamp: ?i64,
            last_modified_utc: ?i64,

            pub fn deinit(row: @This(), allocator: Allocator) void {
                // Fetches allocated fields in reverse order
                const dealloc_fields = comptime deallocFields(@This());
                // IMPORTANT: Have to free memory in reverse, important when using FixedBufferAllocator.
                // FixedBufferAllocator stack part uses end_index to keep track of available memory
                inline for (dealloc_fields) |field| {
                    const val = @field(row, field.name);
                    if (field.is_optional) {
                        if (val) |v| allocator.free(v);
                    } else {
                        allocator.free(val);
                    }
                }
            }
        };

        const base_query =
            \\SELECT
            \\  feed.location as location,
            \\  etag,
            \\  feed_id,
            \\  feed.updated_timestamp as updated_timestamp,
            \\  last_modified_utc
            \\FROM feed_update_http
            \\LEFT JOIN feed ON feed_update_http.feed_id = feed.id
        ;

        const query = if (opts.force) base_query else base_query ++ "\nWHERE update_countdown < 0;";
        var stmt = try self.db.sql_db.prepareDynamic(query);
        defer stmt.deinit();

        var stack_fallback = std.heap.stackFallback(256, self.allocator);
        const stack_allocator = stack_fallback.get();
        var iter = try stmt.iterator(UrlFeed, .{});

        while (try iter.nextAlloc(stack_allocator, .{})) |row| {
            defer row.deinit(stack_allocator);
            log.info("Updating: '{s}'", .{row.location});
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            // TODO: pull out resolveUrl and parsing into separate function?
            const resp_union = try opts.resolveUrl(&arena, row.location, row.last_modified_utc, row.etag);

            switch (resp_union) {
                .not_modified => {
                    log.info("Skipping update. Feed hasn't been modified.", .{});
                    continue;
                },
                .fail => |msg| {
                    log.info("Skipping update. Failed http request: {s}.", .{msg});
                    continue;
                },
                .ok => {},
            }

            const resp = resp_union.ok;
            const rss_feed = switch (resp.content_type) {
                .xml_atom => parse.Atom.parse(&arena, resp.body) catch {
                    log.warn("Skipping update. Failed to parse Atom feed.", .{});
                    continue;
                },
                .xml_rss => parse.Rss.parse(&arena, resp.body) catch {
                    log.warn("Skipping update. Failed to parse RSS feed.", .{});
                    continue;
                },
                else => parse.parse(&arena, resp.body) catch {
                    log.warn("Skipping update. Failed to parse XML file.", .{});
                    continue;
                },
            };

            var savepoint = try self.db.sql_db.savepoint("updateUrlFeeds");
            defer savepoint.rollback();
            const update_data = UpdateData{
                .current = .{ .feed_id = row.feed_id, .updated_timestamp = row.updated_timestamp },
                .headers = resp.headers,
                .feed = rss_feed,
            };
            try self.updateUrlFeed(update_data, opts);
            savepoint.commit();
            log.info("Updated: '{s}'", .{row.location});
        }
    }

    pub const CurrentData = struct { feed_id: u64, updated_timestamp: ?i64 };
    const UpdateData = struct {
        current: CurrentData,
        feed: parse.Feed,
        headers: http.RespHeaders,
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
            try self.db.exec(del_query, .{ r.feed_id, r.count - g.max_items_per_feed });
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
        const query = "INSERT INTO feed_tag (feed_id, tag) VALUES (?, ?) ON CONFLICT(feed_id, tag) DO NOTHING;";
        for (tags) |tag| {
            try self.db.exec(query, .{ feed_id, tag });
        }
    }

    pub fn addTagsById(self: *Self, tags: [][]const u8, feed_id: u64) !void {
        _ = (try self.db.one(void, "select id from feed where id = ?;", .{feed_id})) orelse {
            log.err("Failed to find feed with id '{d}'", .{feed_id});
            return;
        };
        const query = "INSERT INTO feed_tag (feed_id, tag) VALUES (?, ?) ON CONFLICT(feed_id, tag) DO NOTHING;";
        for (tags) |tag| {
            try self.db.exec(query, .{ feed_id, tag });
        }
    }

    pub fn removeTagsByLocation(self: *Self, tags: [][]const u8, location: []const u8) !void {
        const query = "DELETE FROM feed_tag WHERE tag = ? AND location = (SELECT id FROM feed WHERE location = ?);";
        for (tags) |tag| {
            try self.db.exec(query, .{ tag, location });
        }
    }

    pub fn removeTagsById(self: *Self, tags: [][]const u8, id: u64) !void {
        const query = "DELETE FROM feed_tag WHERE tag = ? AND id = ?;";
        for (tags) |tag| {
            try self.db.exec(query, .{ tag, id });
        }
    }

    pub fn removeTags(self: *Self, tags: [][]const u8) !void {
        const query = "DELETE FROM feed_tag WHERE tag = ?;";
        for (tags) |tag| {
            try self.db.exec(query, .{tag});
        }
    }
};

fn equalNullString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return mem.eql(u8, a.?, b.?);
}

fn testDataRespOk() http.Ok {
    const contents = @embedFile("../test/sample-rss-2.xml");
    const location = "https://lobste.rs/";
    return http.Ok{
        .location = location,
        .body = contents,
        .content_type = http.ContentType.xml_rss,
        .headers = .{ .etag = "etag_value" },
    };
}

pub fn testResolveRequest(
    _: *std.heap.ArenaAllocator,
    _: []const u8, // url
    _: ?i64, // last_modified
    _: ?[]const u8, // etag
) !http.FeedResponse {
    const ok = testDataRespOk();
    return http.FeedResponse{ .ok = ok };
}

// Can't run this test with cli.zig addFeedHttp tests
// Will throw a type signature error pertaining to UpdateOptions.resolveUrl function
// Don't run feed_db.zig and cli.zig tests that touch UpdateOptions together
test "Storage fake net" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_data = testDataRespOk();
    var feed_db = try Storage.init(allocator, null);
    var feed = try parse.parse(&arena, test_data.body);

    var savepoint = try feed_db.db.sql_db.savepoint("test_net");
    defer savepoint.rollback();
    const id = try feed_db.addFeed(feed, test_data.location);
    try feed_db.addFeedUrl(id, test_data.headers);

    const ItemsResult = struct { title: []const u8 };
    const all_items_query = "select title from item order by id DESC";

    // No items yet
    const saved_items = try feed_db.db.selectAll(ItemsResult, all_items_query, .{});
    try expect(saved_items.len == 0);

    // Add some items
    const start_index = 3;
    try expect(start_index < feed.items.len);
    const items_src = feed.items[3..];
    var tmp_items = try allocator.alloc(parse.Feed.Item, items_src.len);
    std.mem.copy(parse.Feed.Item, tmp_items, items_src);
    try feed_db.addItems(id, tmp_items);
    {
        const items = try feed_db.db.selectAll(ItemsResult, all_items_query, .{});
        try expect(items.len == items_src.len);
        for (items) |item, i| {
            try std.testing.expectEqualStrings(items_src[i].title, item.title);
        }
    }

    // update feed
    try feed_db.updateUrlFeeds(.{ .force = true, .resolveUrl = testResolveRequest });
    {
        const items = try feed_db.db.selectAll(ItemsResult, all_items_query, .{});
        try expect(items.len == feed.items.len);
        for (items) |item, i| {
            try std.testing.expectEqualStrings(feed.items[i].title, item.title);
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
    const id = try feed_db.addFeed(feed, abs_path);
    try feed_db.addFeedLocal(id, mtime_sec);
    const last_items = feed.items[3..];
    var tmp_items = try allocator.alloc(parse.Feed.Item, last_items.len);
    std.mem.copy(parse.Feed.Item, tmp_items, last_items);
    try feed_db.addItems(id, tmp_items);
    try feed_db.addTags(id, "local,local,not-net");

    const LocalItem = struct { title: []const u8 };
    const all_items_query = "select title from item order by id DESC";

    // Feed local
    {
        const items = try feed_db.db.selectAll(LocalItem, all_items_query, .{});
        try expect(items.len == last_items.len);
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
    const items_base = [_]parse.Feed.Item{
        .{ .title = "title1", .id = "same_id1" },
        .{ .title = "title2", .id = "same_id2" },
    };
    const parsed_feed = parse.Feed{
        .title = "Same stuff",
    };
    const id1 = try storage.addFeed(parsed_feed, location1);
    var items: [items_base.len]parse.Feed.Item = undefined;
    mem.copy(parse.Feed.Item, &items, &items_base);
    try storage.addItems(id1, &items);
    const location2 = "location2";
    const id2 = try storage.addFeed(parsed_feed, location2);
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

test "updateUrlFeeds: check that only neccessary url feeds are updated" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = try Storage.init(allocator, null);

    {
        const location1 = "location1";
        const parsed_feed = parse.Feed{ .title = "Title: location 1" };
        const id1 = try storage.addFeed(parsed_feed, location1);
        const ok1 = http.Ok{
            .location = "feed_location1",
            .body = "",
            .expires_utc = std.math.maxInt(i64), // no update
        };
        try storage.addFeedUrl(id1, ok1);
    }
    {
        const location1 = "location2";
        const parsed_feed = parse.Feed{ .title = "Title: location 2" };
        const id1 = try storage.addFeed(parsed_feed, location1);
        const ok1 = http.Ok{
            .location = "feed_location2",
            .body = "",
            .cache_control_max_age = 300,
        };
        try storage.addFeedUrl(id1, ok1);
        // will update feed
        const query = "update feed_update_http set last_update = ? where feed_id = ?;";
        try storage.db.exec(query, .{ std.math.maxInt(u32), id1 });
    }

    {
        const location1 = "location3";
        const parsed_feed = parse.Feed{ .title = "Title: location 3" };
        const id1 = try storage.addFeed(parsed_feed, location1);
        const ok1 = http.Ok{
            .location = "feed_location3",
            .body = "",
        };
        try storage.addFeedUrl(id1, ok1);
        // will update feed
        const query = "update feed_update_http set last_update = ? where feed_id = ?;";
        try storage.db.exec(query, .{ std.math.maxInt(u32), id1 });
    }

    try storage.updateUrlFeeds(Storage.UpdateOptions{ .resolveUrl = testResolveRequest });
    const query_last_update = "select last_update from feed_update_http";
    {
        const last_updates = try storage.db.selectAll(i64, query_last_update, .{});
        for (last_updates) |last_update| try expect(last_update < std.math.maxInt(u32));
    }

    try storage.db.exec("update feed_update_http set last_update = 0;", .{});
    try storage.updateUrlFeeds(Storage.UpdateOptions{ .resolveUrl = testResolveRequest, .force = true });

    {
        const last_updates = try storage.db.selectAll(i64, query_last_update, .{});
        for (last_updates) |last_update| try expect(last_update > 0);
    }
}
