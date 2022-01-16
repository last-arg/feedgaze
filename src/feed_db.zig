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
const datetime = @import("datetime").datetime;
const Datetime = datetime.Datetime;
const ArrayList = std.ArrayList;
const Table = @import("queries.zig").Table;

pub const g = struct {
    pub var max_items_per_feed: u16 = 10;
};

// TODO?: rename to Storage?
pub const FeedDb = struct {
    const Self = @This();
    // db: sql.Db,
    db: db.Db,
    allocator: Allocator,

    pub fn init(allocator: Allocator, location: ?[]const u8) !Self {
        var sql_db = try db.createDb(allocator, location);
        try db.setup(&sql_db);
        return Self{ .db = db.Db{ .sql_db = sql_db, .allocator = allocator }, .allocator = allocator };
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
        try db.delete(&self.db, "DELETE FROM feed WHERE id = ?", .{id});
    }

    pub fn addFeedUrl(self: *Self, feed_id: usize, resp: http.Success) !void {
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

    const UpdateOptions = struct {
        force: bool = false,
    };

    pub fn updateAllFeeds(self: *Self, allocator: Allocator, opts: UpdateOptions) !void {
        try self.updateUrlFeeds(allocator, opts);
        try self.updateLocalFeeds(allocator, opts);
        try self.cleanItems(allocator);
    }

    // TODO: Split network code from updateUrlFeeds()
    // TODO: or pass resolveRequest as callback. use typeof on http.resolveRequest function
    pub fn updateUrlFeeds(self: *Self, cb: anytype, opts: UpdateOptions) !void {
        @setEvalBranchQuota(2000);
        const DbResultUrl = struct {
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

        const query_all =
            \\SELECT
            \\  feed.location as location,
            \\  etag,
            \\  feed_id,
            \\  feed.updated_timestamp as feed_update_timestamp,
            \\  update_interval,
            \\  last_update,
            \\  expires_utc,
            \\  last_modified_utc,
            \\  cache_control_max_age
            \\FROM feed_update_http
            \\LEFT JOIN feed ON feed_update_http.feed_id = feed.id;
        ;

        // TODO: use sqlite iterator instead?
        // Could save memory. Would release after feed's update is done
        const url_updates = try self.db.selectAll(DbResultUrl, query_all, .{});
        // defer allocator.free(url_updates);

        const current_time = std.time.timestamp();

        print("Update feeds. Count: {d}\n", .{url_updates.len});
        // TODO: should do some memory freeing?
        // There could be alot of feeds which would make the memory explode
        for (url_updates) |obj| {
            log.info("Update feed: '{s}'", .{obj.location});
            if (!opts.force) {
                const check_date: i64 = blk: {
                    if (obj.cache_control_max_age) |sec| {
                        // Uses cache_control_max_age, last_update
                        break :blk obj.last_update + sec;
                    }
                    if (obj.expires_utc) |sec| {
                        break :blk sec;
                    }
                    break :blk obj.last_update + @intCast(i64, obj.update_interval);
                };
                if (obj.expires_utc != null and check_date > obj.expires_utc.?) {
                    log.info("\tSkip update: Not needed", .{});
                    continue;
                } else if (check_date > current_time) {
                    log.info("\tSkip update: Not needed", .{});
                    continue;
                }
            }

            var date_buf: [29]u8 = undefined;
            const last_modified: ?[]const u8 = blk: {
                if (obj.last_modified_utc) |last_modified_utc| {
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
            // const resp_union = try http.resolveRequest(&arena, obj.location, last_modified, obj.etag);
            const resp_union = try cb(&arena, obj.location, last_modified, obj.etag);

            switch (resp_union) {
                .not_modified => {
                    log.info("Skipping update: Feed hasn't been modified", .{});
                    continue;
                },
                .fail => |msg| {
                    log.info("Failed http request: {s}", .{msg});
                    continue;
                },
                .success => {},
            }

            // TODO: catch errors and continue loop
            // There might be errors where continuing loop isn't a good idea
            const resp = resp_union.success;
            const rss_feed = switch (resp.content_type) {
                .xml_atom => try parse.Atom.parse(&arena, resp.body),
                .xml_rss => try parse.Rss.parse(&arena, resp.body),
                else => try parse.parse(&arena, resp.body),
            };

            try self.db.exec(Table.feed_update_http.update_id, .{
                resp.cache_control_max_age,
                resp.expires_utc,
                resp.last_modified_utc,
                resp.etag,
                current_time,
                // where
                obj.feed_id,
            });

            if (!opts.force) {
                if (rss_feed.updated_timestamp != null and obj.feed_updated_timestamp != null and
                    rss_feed.updated_timestamp.? == obj.feed_updated_timestamp.?)
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
                obj.feed_id,
            });

            try self.addItems(obj.feed_id, rss_feed.items);
            log.info("Update finished: '{s}'", .{obj.location});
        }
    }

    pub fn updateLocalFeeds(self: *Self, allocator: Allocator, opts: UpdateOptions) !void {
        const DbResultLocal = struct {
            location: []const u8,
            feed_id: usize,
            feed_updated_timestamp: ?i64,
            update_interval: usize,
            last_update: i64,
            last_modified_timestamp: ?i64,
        };

        const local_updates = try db.selectAll(DbResultLocal, allocator, &self.db, Table.feed_update_local.selectAllWithLocation, .{});
        defer allocator.free(local_updates);

        if (local_updates.len == 0) {
            return;
        }

        var contents = try ArrayList(u8).initCapacity(allocator, 4096);
        defer contents.deinit();

        const update_local =
            \\UPDATE feed_update_local SET
            \\  last_modified_timestamp = ?,
            \\  last_update = (strftime('%s', 'now'))
            \\WHERE feed_id = ?
        ;

        for (local_updates) |obj| {
            log.info("Update feed (local): '{s}'", .{obj.location});
            const file = try std.fs.openFileAbsolute(obj.location, .{});
            defer file.close();
            var file_stat = try file.stat();
            if (!opts.force) {
                if (obj.last_modified_timestamp) |last_modified| {
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
            var rss_feed = try parse.parse(allocator, contents.items);
            const mtime_sec = @intCast(i64, @divFloor(file_stat.mtime, time.ns_per_s));

            try db.update(&self.db, update_local, .{
                mtime_sec,
                // where
                obj.feed_id,
            });

            if (!opts.force) {
                if (rss_feed.updated_timestamp != null and obj.feed_updated_timestamp != null and
                    rss_feed.updated_timestamp.? == obj.feed_updated_timestamp.?)
                {
                    log.info("\tSkipping update: Feed updated/pubDate hasn't changed", .{});
                    continue;
                }
            }

            try db.update(&self.db, Table.feed.update_where_id, .{
                rss_feed.title,
                rss_feed.link,
                rss_feed.updated_raw,
                rss_feed.updated_timestamp,
                // where
                obj.feed_id,
            });

            try self.addItems(obj.feed_id, rss_feed.items);
            log.info("Update finished: '{s}'", .{obj.location});
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

    pub fn cleanItems(self: *Self, allocator: Allocator) !void {
        const query =
            \\SELECT
            \\  feed_id, count(feed_id) as count
            \\FROM item
            \\GROUP BY feed_id
            \\HAVING count(feed_id) > ?{usize}
        ;

        const DbResult = struct {
            feed_id: usize,
            count: usize,
        };

        const results = try db.selectAll(DbResult, allocator, &self.db, query, .{g.max_items_per_feed});

        const del_query =
            \\DELETE FROM item
            \\WHERE id IN (SELECT id
            \\  FROM item
            \\  WHERE feed_id = ?
            \\  ORDER BY pub_date_utc ASC, created_at ASC LIMIT ?
            \\)
        ;
        for (results) |r| {
            try db.delete(&self.db, del_query, .{ r.feed_id, r.count - g.max_items_per_feed });
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

fn testDataRespOk() http.Success {
    const location = "https://lobste.rs/";
    const contents = @embedFile("../test/sample-rss-2.xml");
    return http.Success{
        .location = location,
        .body = contents,
        .content_type = http.ContentType.xml_rss,
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
    return http.FeedResponse{ .success = ok };
}

test "@active FeedDb(fake net) addItems(), updateUrlFeeds()" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_data = testDataRespOk();
    var feed_db = try FeedDb.init(allocator, null);
    var feed = try parse.parse(&arena, test_data.body);

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
    try feed_db.updateUrlFeeds(testResolveRequest, .{ .force = true });
    {
        const items = try feed_db.db.selectAll(ItemsResult, all_items_query, .{});
        try expect(items.len == feed.items.len);
        for (items) |item, i| {
            try std.testing.expectEqualStrings(feed.items[i].title, item.title);
        }
    }
}

// TODO?: remove/redo?
test "FeedDb(local): add, update, remove" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var feed_db = try FeedDb.init(allocator, null);

    // const abs_path = "/media/hdd/code/feed_app/test/sample-rss-2.xml";
    const rel_path = "test/sample-rss-2.xml";
    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    const abs_path = try fs.cwd().realpath(rel_path, &path_buf);
    const contents = try shame.getFileContents(allocator, abs_path);
    const file = try fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const stat = try file.stat();
    const mtime_sec = @intCast(i64, @divFloor(stat.mtime, time.ns_per_s));

    var feed = try parse.parse(&arena, contents);

    const all_items = feed.items;
    feed.items = all_items[0..3];
    const id = try feed_db.addFeed(feed, abs_path);
    try feed_db.addFeedLocal(id, mtime_sec);
    try feed_db.addItems(id, feed.items);

    const LocalResult = struct {
        location: []const u8,
        link: ?[]const u8,
        title: []const u8,
        updated_raw: ?[]const u8,
        id: usize,
        updated_timestamp: ?i64,
    };

    const all_feeds_query = "select location, link, title, updated_raw, id, updated_timestamp from feed";

    // Feed local
    {
        const feed_dbfeeds = try db.selectAll(LocalResult, allocator, &feed_db.db, all_feeds_query, .{});
        try expect(feed_dbfeeds.len == 1);
        const first = feed_dbfeeds[0];
        try expect(first.id == 1);
        try expect(mem.eql(u8, abs_path, first.location));
        try expect(mem.eql(u8, feed.link.?, first.link.?));
        try expect(mem.eql(u8, feed.title, first.title));
        try expect(mem.eql(u8, feed.updated_raw.?, first.updated_raw.?));
        try expect(feed.updated_timestamp.? == first.updated_timestamp.?);
    }

    const LocalUpdateResult = struct {
        feed_id: usize,
        update_interval: usize,
        last_update: i64,
        last_modified_timestamp: i64,
    };

    const local_query = "select feed_id, update_interval, last_update, last_modified_timestamp from feed_update_local";

    // Local feed update
    {
        const feed_dbfeeds = try db.selectAll(LocalUpdateResult, allocator, &feed_db.db, local_query, .{});
        try expect(feed_dbfeeds.len == 1);
        const first = feed_dbfeeds[0];
        try expect(first.feed_id == 1);
        try expect(first.update_interval == 600);
        const current_time = std.time.timestamp();
        try expect(first.last_update <= current_time);
        try expect(first.last_modified_timestamp == mtime_sec);
    }

    const ItemsResult = struct {
        link: ?[]const u8,
        title: []const u8,
        guid: ?[]const u8,
        id: usize,
        feed_id: usize,
        pub_date: ?[]const u8,
        pub_date_utc: ?i64,
    };

    const all_items_query = "select link, title, guid, id, feed_id, pub_date, pub_date_utc from item order by pub_date_utc";

    // Items
    {
        const items = try db.selectAll(ItemsResult, allocator, &feed_db.db, all_items_query, .{});
        try expect(items.len == feed.items.len);
    }

    try feed_db.updateAllFeeds(allocator, .{ .force = true });
    feed.items = all_items;

    // Items
    {
        const items = try db.selectAll(ItemsResult, allocator, &feed_db.db, all_items_query, .{});
        try expect(items.len == feed.items.len);

        parse.Feed.sortItemsByDate(feed.items);
        for (items) |feed_dbitem, i| {
            const f_item = feed.items[i];
            try expect(equalNullString(feed_dbitem.link, f_item.link));
            try expect(equalNullString(feed_dbitem.guid, f_item.id));
            try std.testing.expectEqualStrings(feed_dbitem.title, f_item.title);
            try expect(equalNullString(feed_dbitem.pub_date, f_item.updated_raw));
            try expect(std.meta.eql(feed_dbitem.pub_date_utc, f_item.updated_timestamp));
            try expect(feed_dbitem.feed_id == 1);
        }
    }

    // Local feed update
    {
        const local_updates = try db.selectAll(LocalUpdateResult, allocator, &feed_db.db, local_query, .{});
        try expect(local_updates.len == 1);
        const first = local_updates[0];
        try expect(first.feed_id == 1);
        try expect(first.update_interval == 600);
        const current_time = std.time.timestamp();
        try expect(first.last_update <= current_time);
        try expect(first.last_modified_timestamp == mtime_sec);
    }

    const item_count_query = "select count(id) from item";

    // Delete items that are over max item limit
    {
        var item_count = try db.count(&feed_db.db, item_count_query);
        try expect(feed.items.len == item_count);

        // cleanItemsByFeedId()
        g.max_items_per_feed = 4;
        try feed_db.cleanItemsByFeedId(1);
        item_count = try db.count(&feed_db.db, item_count_query);
        try expect(g.max_items_per_feed == item_count);

        // cleanItems()
        g.max_items_per_feed = 2;
        try feed_db.cleanItems(allocator);
        item_count = try db.count(&feed_db.db, item_count_query);
        try expect(g.max_items_per_feed == item_count);
    }

    // Delete feed
    {
        try feed_db.deleteFeed(1);

        const feed_count = try db.count(&feed_db.db, "select count(id) from feed");
        try expect(feed_count == 0);
        const local_update_count = try db.count(&feed_db.db, "select count(feed_id) from feed_update_local");
        try expect(local_update_count == 0);
        const item_count = try db.count(&feed_db.db, item_count_query);
        try expect(item_count == 0);
    }
}
