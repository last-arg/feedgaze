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
const expectEqualStrings = std.testing.expectEqualStrings;
const datetime = @import("datetime").datetime;
const Datetime = datetime.Datetime;
const ArrayList = std.ArrayList;
const Table = @import("queries.zig").Table;

pub const g = struct {
    pub var max_items_per_feed: u16 = 10;
};

// TODO: sqlite primary keys are 64 bit
pub const Storage = struct {
    const Self = @This();
    db: db.Db,
    allocator: Allocator,

    pub fn init(allocator: Allocator, location: ?[:0]const u8) !Self {
        return Self{ .db = try db.Db.init(allocator, location), .allocator = allocator };
    }

    pub fn addFeed(self: *Self, feed: parse.Feed, location: []const u8) !usize {
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
            \\WHERE updated_timestamp != excluded.updated_timestamp
            \\RETURNING id;
        ;
        const args = .{ feed.title, location, feed.link, feed.updated_raw, feed.updated_timestamp };
        return (try self.db.one(usize, query, args)) orelse error.NoReturnId;
    }

    pub fn deleteFeed(self: *Self, id: usize) !void {
        try self.db.exec("DELETE FROM feed WHERE id = ?", .{id});
    }

    pub fn addFeedUrl(self: *Self, feed_id: usize, resp: http.Ok) !void {
        const query =
            \\INSERT INTO feed_update_http
            \\  (feed_id, cache_control_max_age, expires_utc, last_modified_utc, etag)
            \\VALUES (
            \\  ?{usize},
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
            feed_id, resp.cache_control_max_age, resp.expires_utc, resp.last_modified_utc, resp.etag,
        });
    }

    pub fn addFeedLocal(
        self: *Self,
        feed_id: usize,
        last_modified: i64,
    ) !void {
        const query =
            \\INSERT INTO feed_update_local
            \\  (feed_id, last_modified_timestamp)
            \\VALUES (
            \\  ?{usize},
            \\  ?{i64}
            \\)
            \\ON CONFLICT(feed_id) DO UPDATE SET
            \\  last_modified_timestamp = excluded.last_modified_timestamp,
            \\  last_update = (strftime('%s', 'now'))
        ;
        _ = query;
        try self.db.exec(Table.feed_update_local.insert ++ Table.feed_update_local.on_conflict_feed_id, .{
            feed_id, last_modified,
        });
    }

    pub fn addItems(self: *Self, feed_id: usize, feed_items: []parse.Feed.Item) !void {
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

            break :blk hasGuid and hasLink;
        };
        const insert_query =
            \\INSERT INTO item (feed_id, title, link, guid, pub_date, pub_date_utc)
            \\VALUES (
            \\  ?{usize},
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
                \\  created_at = (strftime('%s', 'now'))
                \\WHERE
                \\  excluded.feed_id = feed_id
                \\  AND excluded.pub_date_utc != pub_date_utc
            ;
            const query = insert_query ++ "\nON CONFLICT(guid) " ++ conflict_update ++ "\nON CONFLICT(link)" ++ conflict_update ++ ";";

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
                \\  ?{usize},
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
        const UrlFeed = struct {
            location: []const u8,
            etag: ?[]const u8,
            feed_id: usize,
            feed_updated_timestamp: ?i64,
            update_interval: usize,
            last_update: i64,
            expires_utc: ?i64,
            last_modified_utc: ?i64,
            cache_control_max_age: ?i64,
        };

        const dealloc_fields = comptime deallocFields(UrlFeed);
        const query_all =
            \\SELECT
            \\  feed.location as location,
            \\  etag,
            \\  feed_id,
            \\  feed.updated_timestamp as feed_updated_timestamp,
            \\  update_interval,
            \\  last_update,
            \\  expires_utc,
            \\  last_modified_utc,
            \\  cache_control_max_age
            \\FROM feed_update_http
            \\LEFT JOIN feed ON feed_update_http.feed_id = feed.id;
        ;

        const current_time = std.time.timestamp();
        var stack_fallback = std.heap.stackFallback(256, self.allocator);
        const stack_allocator = stack_fallback.get();
        var stmt = try self.db.sql_db.prepare(query_all);
        defer stmt.deinit();
        var iter = try stmt.iterator(UrlFeed, .{});
        while (try iter.nextAlloc(stack_allocator, .{})) |row| {
            defer {
                // IMPORTANT: Have to free memory in reverse, important when using FixedBufferAllocator.
                // FixedBufferAllocator uses end_index to keep track of available memory
                //
                // dealloc_fields are in reverse order
                inline for (dealloc_fields) |field| {
                    const val = @field(row, field.name);
                    if (field.is_optional) stack_allocator.free(val.?) else stack_allocator.free(val);
                }
            }

            log.info("Updating: '{s}'", .{row.location});
            if (!opts.force) {
                // TODO: maybe can move these checks into SQL?
                const check_date: i64 = blk: {
                    if (row.cache_control_max_age) |sec| {
                        // Uses cache_control_max_age, last_update
                        break :blk row.last_update + sec;
                    }
                    if (row.expires_utc) |sec| {
                        break :blk sec;
                    }
                    break :blk row.last_update + @intCast(i64, row.update_interval);
                };
                if (row.expires_utc != null and check_date > row.expires_utc.?) {
                    log.info("\tSkip update: Not needed", .{});
                    continue;
                } else if (check_date > current_time) {
                    log.info("\tSkip update: Not needed", .{});
                    continue;
                }
            }

            var date_buf: [29]u8 = undefined;
            const last_modified: ?[]const u8 = blk: {
                if (row.last_modified_utc) |last_modified_utc| {
                    const date = Datetime.fromTimestamp(last_modified_utc);
                    const date_fmt = "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT";
                    const date_str = try std.fmt.bufPrint(&date_buf, date_fmt, .{
                        date.date.weekdayName()[0..3],
                        date.date.day,
                        date.date.monthName()[0..3],
                        date.date.year,
                        date.time.hour,
                        date.time.minute,
                        date.time.second,
                    });
                    break :blk date_str;
                }
                break :blk null;
            };

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const resp_union = try opts.resolveUrl(&arena, row.location, last_modified, row.etag);

            switch (resp_union) {
                .not_modified => {
                    log.info("Skipping update: Feed hasn't been modified", .{});
                    continue;
                },
                .fail => |msg| {
                    log.info("Failed http request: {s}", .{msg});
                    continue;
                },
                .ok => {},
            }

            // TODO: catch errors and continue loop
            // There might be errors where continuing loop isn't a good idea
            const resp = resp_union.ok;
            const rss_feed = switch (resp.content_type) {
                .xml_atom => try parse.Atom.parse(&arena, resp.body),
                .xml_rss => try parse.Rss.parse(&arena, resp.body),
                else => try parse.parse(&arena, resp.body),
            };

            const update_feed_row = .{ .feed_id = row.feed_id, .updated_timestamp = row.feed_updated_timestamp };
            try self.updateUrlFeed(update_feed_row, resp, rss_feed, opts);
            log.info("Updated: '{s}'", .{row.location});
        }
    }

    pub const UpdateFeedRow = struct { feed_id: usize, updated_timestamp: ?i64 };
    pub fn updateUrlFeed(
        self: *Self,
        row: UpdateFeedRow,
        resp: http.Ok,
        feed: parse.Feed,
        opts: UpdateOptions,
    ) !void {
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
            resp.cache_control_max_age,
            resp.expires_utc,
            resp.last_modified_utc,
            resp.etag,
            // where
            row.feed_id,
        });

        if (!opts.force) {
            if (feed.updated_timestamp != null and row.updated_timestamp != null and
                feed.updated_timestamp.? == row.updated_timestamp.?)
            {
                log.info("\tSkipping update: Feed updated/pubDate hasn't changed", .{});
                return;
            }
        }

        try self.db.exec(Table.feed.update_where_id, .{
            feed.title,       feed.link,
            feed.updated_raw, feed.updated_timestamp,
            // where
            row.feed_id,
        });

        try self.addItems(row.feed_id, feed.items);
    }

    pub fn updateLocalFeeds(self: *Self, opts: UpdateOptions) !void {
        const LocalFeed = struct {
            location: []const u8,
            feed_id: usize,
            feed_updated_timestamp: ?i64,
            update_interval: usize,
            last_update: i64,
            last_odified_timestamp: ?i64,
        };

        var contents = try ArrayList(u8).initCapacity(self.allocator, 4096);
        defer contents.deinit();

        const query_update_local =
            \\UPDATE feed_update_local SET
            \\  last_modified_timestamp = ?,
            \\  last_update = (strftime('%s', 'now'))
            \\WHERE feed_id = ?
        ;

        var stack_fallback = std.heap.stackFallback(256, self.allocator);
        const stack_allocator = stack_fallback.get();
        var stmt = try self.db.sql_db.prepare(Table.feed_update_local.selectAllWithLocation);
        defer stmt.deinit();
        var iter = try stmt.iterator(LocalFeed, .{});
        while (try iter.nextAlloc(stack_allocator, .{})) |row| {
            defer stack_allocator.free(row.location);
            log.info("Updating: '{s}'", .{row.location});
            const file = try std.fs.openFileAbsolute(row.location, .{});
            defer file.close();
            var file_stat = try file.stat();
            if (!opts.force) {
                if (row.last_modified_timestamp) |last_modified| {
                    const mtime_sec = @intCast(i64, @divFloor(file_stat.mtime, time.ns_per_s));
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
            const mtime_sec = @intCast(i64, @divFloor(file_stat.mtime, time.ns_per_s));

            try self.db.exec(query_update_local, .{
                mtime_sec,
                // where
                row.feed_id,
            });

            if (!opts.force) {
                if (rss_feed.updated_timestamp != null and row.feed_updated_timestamp != null and
                    rss_feed.updated_timestamp.? == row.feed_updated_timestamp.?)
                {
                    log.info("\tSkipping update: Feed updated/pubDate hasn't changed", .{});
                    continue;
                }
            }

            try self.db.exec(Table.feed.update_where_id, .{
                rss_feed.title,
                rss_feed.link,
                rss_feed.updated_raw,
                rss_feed.updated_timestamp,
                // where
                row.feed_id,
            });

            try self.addItems(row.feed_id, rss_feed.items);
            log.info("Updated: '{s}'", .{row.location});
        }
    }

    pub fn cleanItemsByFeedId(self: *Self, feed_id: usize) !void {
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

        const DbResult = struct { feed_id: usize, count: usize };

        const results = try self.db.selectAll(DbResult, query, .{g.max_items_per_feed});

        const del_query =
            \\DELETE FROM item
            \\WHERE id IN (SELECT id
            \\  FROM item
            \\  WHERE feed_id = ?
            \\  ORDER BY pub_date_utc ASC, created_at ASC LIMIT ?
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
        id: usize,
    };

    pub fn search(self: *Self, allocator: Allocator, term: []const u8) ![]SearchResult {
        const query =
            \\SELECT location, title, link, id FROM feed
            \\WHERE location LIKE ? OR link LIKE ? OR title LIKE ?
        ;
        const search_term = try fmt.allocPrint(allocator, "%{s}%", .{term});
        defer allocator.free(search_term);

        const results = try db.selectAll(SearchResult, allocator, &self.db, query, .{
            search_term,
            search_term,
            search_term,
        });
        return results;
    }
};

fn equalNullString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return mem.eql(u8, a.?, b.?);
}

fn testDataRespOk() http.Ok {
    const location = "https://lobste.rs/";
    const contents = @embedFile("../test/sample-rss-2.xml");
    return http.Ok{
        .location = location,
        .body = contents,
        .content_type = http.ContentType.xml_rss,
        .etag = "etag_value",
    };
}

pub fn testResolveRequest(
    _: *std.heap.ArenaAllocator,
    url: []const u8,
    _: ?[]const u8,
    _: ?[]const u8,
) !http.FeedResponse {
    const ok = testDataRespOk();
    try std.testing.expectEqualStrings(url, ok.location);
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
    try feed_db.addFeedUrl(id, test_data);

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
        const count_item = try feed_db.db.one(usize, "select count(id) from item", .{});
        try expect(count_item.? == 0);
        const count_feed = try feed_db.db.one(usize, "select count(id) from feed", .{});
        try expect(count_feed.? == 0);
        const count_http = try feed_db.db.one(usize, "select count(feed_id) from feed_update_http", .{});
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
    const rel_path = "test/sample-rss-2.xml";
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

    const LocalItem = struct { title: []const u8 };
    const all_items_query = "select title from item order by id DESC";

    // Feed local
    {
        const items = try feed_db.db.selectAll(LocalItem, all_items_query, .{});
        try expect(items.len == last_items.len);
        for (items) |item, i| {
            try expectEqualStrings(item.title, last_items[i].title);
        }
    }

    const LocalUpdateResult = struct { feed_id: usize, update_interval: usize, last_update: i64, last_modified_timestamp: i64 };
    const local_query = "select feed_id, update_interval, last_update, last_modified_timestamp from feed_update_local";

    // Local feed update
    {
        const count = try feed_db.db.one(usize, "select count(*) from feed_update_local", .{});
        try expect(count.? == 1);
        const feed_dbfeeds = try feed_db.db.one(LocalUpdateResult, local_query, .{});
        const first = feed_dbfeeds.?;
        try expect(first.feed_id == 1);
        try expect(first.update_interval == 600);
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
        const count_item = try feed_db.db.one(usize, "select count(id) from item", .{});
        try expect(count_item.? == 0);
        const count_feed = try feed_db.db.one(usize, "select count(id) from feed", .{});
        try expect(count_feed.? == 0);
        const count_http = try feed_db.db.one(usize, "select count(feed_id) from feed_update_local", .{});
        try expect(count_http.? == 0);
    }
    savepoint.commit();
}
