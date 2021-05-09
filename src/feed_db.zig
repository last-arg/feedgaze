const std = @import("std");
const Allocator = std.mem.Allocator;
const sql = @import("sqlite");
const db = @import("db.zig");
const fs = std.fs;
const fmt = std.fmt;
const log = std.log;
const http = @import("http.zig");
const mem = std.mem;
const shame = @import("shame.zig");
const time = std.time;
const parse = @import("parse.zig");
const expect = std.testing.expect;
const datetime = @import("datetime");
const Datetime = datetime.Datetime;
const ArrayList = std.ArrayList;

usingnamespace @import("queries.zig");

pub const g = struct {
    pub var max_items_per_feed: usize = 10;
};

pub const FeedDb = struct {
    const Self = @This();
    db: sql.Db,

    pub fn init(allocator: *Allocator, location: ?[]const u8) !Self {
        var sql_db = try db.createDb(allocator, location);
        try db.setup(&sql_db);
        return Self{ .db = sql_db };
    }

    pub fn addFeed(self: *Self, feed: parse.Feed, location: []const u8) !usize {
        try db.insert(&self.db, Table.feed.insert ++ Table.feed.on_conflict_location, .{
            feed.title,
            location,
            feed.link,
            feed.updated_raw,
            feed.updated_timestamp,
        });

        const id = (try db.one(
            usize,
            &self.db,
            Table.feed.select_id ++ Table.feed.where_location,
            .{location},
        )) orelse return error.NoFeedWithLocation;

        return id;
    }

    pub fn deleteFeed(self: *Self, id: usize) !void {
        try db.delete(&self.db, "DELETE FROM feed WHERE id = ?", .{id});
    }

    pub fn addFeedUrl(self: *Self, feed_id: usize, resp: http.FeedResponse) !void {
        try db.insert(&self.db, Table.feed_update_http.insert ++ Table.feed_update_http.on_conflict_feed_id, .{
            feed_id,
            resp.cache_control_max_age,
            resp.expires_utc,
            resp.last_modified_utc,
            resp.etag,
        });
    }

    pub fn addFeedLocal(
        self: *Self,
        feed_id: usize,
        last_modified: i64,
    ) !void {
        try db.insert(&self.db, Table.feed_update_local.insert ++ Table.feed_update_local.on_conflict_feed_id, .{
            feed_id, last_modified,
        });
    }

    pub fn addItems(self: *Self, feed_id: usize, feed_items: []parse.Feed.Item) !void {
        parse.Feed.sortItemsByDate(feed_items);
        for (feed_items) |it| {
            if (it.id) |guid| {
                try db.insert(
                    &self.db,
                    Table.item.upsert_guid,
                    .{ feed_id, it.title, guid, it.link, it.updated_raw, it.updated_timestamp },
                );
            } else if (it.link) |link| {
                try db.insert(
                    &self.db,
                    Table.item.upsert_link,
                    .{ feed_id, it.title, link, it.updated_raw, it.updated_timestamp },
                );
            } else {
                const item_id = try db.one(
                    usize,
                    &self.db,
                    Table.item.select_id_by_title,
                    .{ feed_id, it.title },
                );
                if (item_id) |id| {
                    try db.update(&self.db, Table.item.update_date, .{ it.updated_raw, it.updated_timestamp, id, it.updated_timestamp });
                } else {
                    try db.insert(
                        &self.db,
                        Table.item.insert_minimal,
                        .{ feed_id, it.title, it.updated_raw, it.updated_timestamp },
                    );
                }
            }
        }
    }

    const UpdateOptions = struct {
        force: bool = false,
    };

    pub fn updateAllFeeds(self: *Self, allocator: *Allocator, opts: UpdateOptions) !void {
        try self.updateUrlFeeds(allocator, opts);
        try self.updateLocalFeeds(allocator, opts);
        try self.cleanItems(allocator);
    }

    pub fn updateUrlFeeds(self: *Self, allocator: *Allocator, opts: UpdateOptions) !void {
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

        const url_updates = try db.selectAll(DbResultUrl, allocator, &self.db, Table.feed_update_http.selectAllWithLocation, .{});
        defer allocator.free(url_updates);

        const current_time = std.time.timestamp();

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

            const last_modified = blk: {
                if (obj.last_modified_utc) |last_modified_utc| {
                    const date = Datetime.fromTimestamp(last_modified_utc);
                    var date_buf: [29]u8 = undefined;
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
            const req = http.FeedRequest{
                .url = try http.makeUri(obj.location),
                .etag = obj.etag,
                .last_modified = last_modified,
            };

            const resp = try http.resolveRequest(allocator, req);

            if (resp.status_code == 304) {
                log.info("\tSkipping update: Feed hasn't been modified", .{});
                continue;
            }

            if (resp.body == null) {
                log.info("\tSkipping update: HTTP request body is empty", .{});
                continue;
            }

            const body = resp.body.?;
            const rss_feed = switch (resp.content_type) {
                .xml_atom => try parse.Atom.parse(allocator, body),
                .xml_rss => try parse.Rss.parse(allocator, body),
                else => try parse.parse(allocator, body),
            };

            try db.update(&self.db, Table.feed_update_http.update_id, .{
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

    pub fn updateLocalFeeds(self: *Self, allocator: *Allocator, opts: UpdateOptions) !void {
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
            try contents.ensureCapacity(file_stat.size);
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
            \\	(SELECT id FROM item
            \\		WHERE feed_id = ?
            \\		ORDER BY pub_date_utc ASC, created_at ASC
            \\		LIMIT (SELECT MAX(count(feed_id) - ?, 0) FROM item WHERE feed_id = ?)
            \\  )
        ;
        try db.delete(&self.db, query, .{ feed_id, g.max_items_per_feed, feed_id });
    }

    pub fn cleanItems(self: *Self, allocator: *Allocator) !void {
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

    pub fn search(self: *Self, allocator: *Allocator, term: []const u8) ![]SearchResult {
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

test "@active FeedDb(local): add, update, remove" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

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

    var feed = try parse.parse(allocator, contents);

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
        expect(feed_dbfeeds.len == 1);
        const first = feed_dbfeeds[0];
        expect(first.id == 1);
        expect(mem.eql(u8, abs_path, first.location));
        expect(mem.eql(u8, feed.link.?, first.link.?));
        expect(mem.eql(u8, feed.title, first.title));
        expect(mem.eql(u8, feed.updated_raw.?, first.updated_raw.?));
        expect(feed.updated_timestamp.? == first.updated_timestamp.?);
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
        expect(feed_dbfeeds.len == 1);
        const first = feed_dbfeeds[0];
        expect(first.feed_id == 1);
        expect(first.update_interval == 600);
        const current_time = std.time.timestamp();
        expect(first.last_update <= current_time);
        expect(first.last_modified_timestamp == mtime_sec);
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
        expect(items.len == feed.items.len);
    }

    try feed_db.updateAllFeeds(allocator, .{ .force = true });
    feed.items = all_items;

    // Items
    {
        const items = try db.selectAll(ItemsResult, allocator, &feed_db.db, all_items_query, .{});
        expect(items.len == feed.items.len);

        parse.Feed.sortItemsByDate(feed.items);
        for (items) |feed_dbitem, i| {
            const f_item = feed.items[i];
            expect(equalNullString(feed_dbitem.link, f_item.link));
            expect(equalNullString(feed_dbitem.guid, f_item.id));
            std.testing.expectEqualStrings(feed_dbitem.title, f_item.title);
            expect(equalNullString(feed_dbitem.pub_date, f_item.updated_raw));
            expect(std.meta.eql(feed_dbitem.pub_date_utc, f_item.updated_timestamp));
            expect(feed_dbitem.feed_id == 1);
        }
    }

    // Local feed update
    {
        const local_updates = try db.selectAll(LocalUpdateResult, allocator, &feed_db.db, local_query, .{});
        expect(local_updates.len == 1);
        const first = local_updates[0];
        expect(first.feed_id == 1);
        expect(first.update_interval == 600);
        const current_time = std.time.timestamp();
        expect(first.last_update <= current_time);
        expect(first.last_modified_timestamp == mtime_sec);
    }

    const item_count_query = "select count(id) from item";

    // Delete items that are over max item limit
    {
        var item_count = try db.count(&feed_db.db, item_count_query);
        expect(feed.items.len == item_count);

        // cleanItemsByFeedId()
        g.max_items_per_feed = 4;
        try feed_db.cleanItemsByFeedId(1);
        item_count = try db.count(&feed_db.db, item_count_query);
        expect(g.max_items_per_feed == item_count);

        // cleanItems()
        g.max_items_per_feed = 2;
        try feed_db.cleanItems(allocator);
        item_count = try db.count(&feed_db.db, item_count_query);
        expect(g.max_items_per_feed == item_count);
    }

    // Delete feed
    {
        try feed_db.deleteFeed(1);

        const feed_count = try db.count(&feed_db.db, "select count(id) from feed");
        expect(feed_count == 0);
        const local_update_count = try db.count(&feed_db.db, "select count(feed_id) from feed_update_local");
        expect(local_update_count == 0);
        const item_count = try db.count(&feed_db.db, item_count_query);
        expect(item_count == 0);
    }
}
