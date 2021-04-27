const std = @import("std");
const sql = @import("sqlite");
const datetime = @import("datetime");
const http = @import("http.zig");
const Datetime = datetime.Datetime;
const timezones = datetime.timezones;
const parse = @import("parse.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const expect = std.testing.expect;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const time = std.time;
const ascii = std.ascii;
const process = std.process;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const l = std.log;
const db = @import("db.zig");
const Db = db.Db;
usingnamespace @import("queries.zig");

pub const log_level = std.log.Level.info;
const g = struct {
    var max_items_per_feed: usize = 10;
};

fn equalNullString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return mem.eql(u8, a.?, b.?);
}

test "@active local feed: add, update, remove" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var sql_db = try db.createDb(allocator, null);
    try db.setup(&sql_db);
    var db_ = Db_{
        .db = &sql_db,
    };

    // const abs_path = "/media/hdd/code/feed_app/test/sample-rss-2.xml";
    const rel_path = "test/sample-rss-2.xml";
    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    const abs_path = try fs.cwd().realpath(rel_path, &path_buf);
    const contents = try getFileContents(allocator, abs_path);
    const file = try fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const stat = try file.stat();
    const mtime_sec = @intCast(i64, @divFloor(stat.mtime, time.ns_per_s));

    var feed = try parse.parse(allocator, contents);

    const all_items = feed.items;
    feed.items = all_items[0..3];
    const id = try db_.addFeed(feed, abs_path);
    try db_.addFeedLocal(id, mtime_sec);
    try db_.addItems(id, feed.items);

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
        const db_feeds = try db.selectAll(LocalResult, allocator, &sql_db, all_feeds_query, .{});
        expect(db_feeds.len == 1);
        const first = db_feeds[0];
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
        const db_feeds = try db.selectAll(LocalUpdateResult, allocator, &sql_db, local_query, .{});
        expect(db_feeds.len == 1);
        const first = db_feeds[0];
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
        const items = try db.selectAll(ItemsResult, allocator, &sql_db, all_items_query, .{});
        expect(items.len == feed.items.len);
    }

    try db_.updateAllFeeds(allocator, .{ .force = true });
    feed.items = all_items;

    // Items
    {
        const items = try db.selectAll(ItemsResult, allocator, &sql_db, all_items_query, .{});
        expect(items.len == feed.items.len);

        parse.Feed.sortItemsByDate(feed.items);
        for (items) |db_item, i| {
            const f_item = feed.items[i];
            expect(equalNullString(db_item.link, f_item.link));
            expect(equalNullString(db_item.guid, f_item.id));
            std.testing.expectEqualStrings(db_item.title, f_item.title);
            expect(equalNullString(db_item.pub_date, f_item.updated_raw));
            expect(std.meta.eql(db_item.pub_date_utc, f_item.updated_timestamp));
            expect(db_item.feed_id == 1);
        }
    }

    // Local feed update
    {
        const local_updates = try db.selectAll(LocalUpdateResult, allocator, &sql_db, local_query, .{});
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
        var item_count = try db.count(&sql_db, item_count_query);
        expect(feed.items.len == item_count);

        g.max_items_per_feed = 4;
        try db_.deleteItemsById(1);
        item_count = try db.count(&sql_db, item_count_query);
        expect(g.max_items_per_feed == item_count);
    }

    // Delete feed
    {
        try db_.deleteFeed(1);

        const feed_count = try db.count(&sql_db, "select count(id) from feed");
        expect(feed_count == 0);
        const local_update_count = try db.count(&sql_db, "select count(feed_id) from feed_update_local");
        expect(local_update_count == 0);
        const item_count = try db.count(&sql_db, item_count_query);
        expect(item_count == 0);
    }
}

const Db_ = struct {
    const Self = @This();
    db: *sql.Db,

    pub fn addFeed(self: Self, feed: parse.Feed, location: []const u8) !usize {
        try db.insert(self.db, Table.feed.insert ++ Table.feed.on_conflict_location, .{
            feed.title,
            location,
            feed.link,
            feed.updated_raw,
            feed.updated_timestamp,
        });

        const id = (try db.one(
            usize,
            self.db,
            Table.feed.select_id ++ Table.feed.where_location,
            .{location},
        )) orelse return error.NoFeedWithLocation;

        return id;
    }

    pub fn deleteFeed(self: Self, id: usize) !void {
        try db.delete(self.db, "DELETE FROM feed WHERE id = ?", .{id});
    }

    pub fn addFeedUrl(self: Self, feed_id: usize, resp: http.FeedResponse) !void {
        try db.insert(self.db, Table.feed_update_http.insert ++ Table.feed_update_http.on_conflict_feed_id, .{
            id,
            resp.cache_control_max_age,
            resp.expires_utc,
            resp.last_modified_utc,
            resp.etag,
        });
    }

    pub fn addFeedLocal(
        self: Self,
        id: usize,
        last_modified: i64,
    ) !void {
        try db.insert(self.db, Table.feed_update_local.insert ++ Table.feed_update_local.on_conflict_feed_id, .{
            id, last_modified,
        });
    }

    pub fn addItems(self: Self, feed_id: usize, feed_items: []parse.Feed.Item) !void {
        parse.Feed.sortItemsByDate(feed_items);
        for (feed_items) |it| {
            if (it.id) |guid| {
                try db.insert(
                    self.db,
                    Table.item.upsert_guid,
                    .{ feed_id, it.title, guid, it.link, it.updated_raw, it.updated_timestamp },
                );
            } else if (it.link) |link| {
                try db.insert(
                    self.db,
                    Table.item.upsert_link,
                    .{ feed_id, it.title, link, it.updated_raw, it.updated_timestamp },
                );
            } else {
                const item_id = try db.one(
                    usize,
                    self.db,
                    Table.item.select_id_by_title,
                    .{ feed_id, it.title },
                );
                if (item_id) |id| {
                    try db.update(self.db, Table.item.update_date, .{ it.updated_raw, it.updated_timestamp, id, it.updated_timestamp });
                } else {
                    try db.insert(
                        self.db,
                        Table.item.insert_minimal,
                        .{ feed_id, it.title, it.updated_raw, it.updated_timestamp },
                    );
                }
            }
        }
    }

    pub fn updateAllFeeds(self: Self, allocator: *Allocator, opts: struct { force: bool = false }) !void {
        @setEvalBranchQuota(2000);

        // Update url feeds
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

        const url_updates = try db.selectAll(DbResultUrl, allocator, self.db, Table.feed_update_http.selectAllWithLocation, .{});
        defer allocator.free(url_updates);

        const current_time = std.time.timestamp();

        for (url_updates) |obj| {
            l.info("Update feed: '{s}'", .{obj.location});
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
                    l.info("\tSkip update: Not needed", .{});
                    continue;
                } else if (check_date > current_time) {
                    l.info("\tSkip update: Not needed", .{});
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
                .url = try http.makeUrl(obj.location),
                .etag = obj.etag,
                .last_modified = last_modified,
            };

            const resp = try http.resolveRequest(allocator, req);

            if (resp.status_code == 304) {
                l.info("\tSkipping update: Feed hasn't been modified", .{});
                continue;
            }

            if (resp.body == null) {
                l.info("\tSkipping update: HTTP request body is empty", .{});
                continue;
            }

            const body = resp.body.?;
            const rss_feed = switch (resp.content_type) {
                .xml_atom => try parse.Atom.parse(allocator, body),
                .xml_rss => try parse.Rss.parse(allocator, body),
                else => try parse.parse(allocator, body),
            };

            try db.update(self.db, Table.feed_update_http.update_id, .{
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
                    l.info("\tSkipping update: Feed updated/pubDate hasn't changed", .{});
                    continue;
                }
            }

            try db.update(self.db, Table.feed.update_where_id, .{
                rss_feed.title,
                rss_feed.link,
                rss_feed.updated_raw,
                rss_feed.updated_timestamp,
                // where
                obj.feed_id,
            });

            try self.addItems(obj.feed_id, rss_feed.items);
            // TODO: remove extra feed items
            l.info("\tUpdate finished: '{s}'", .{obj.location});
        }

        // Update local file feeds
        const DbResultLocal = struct {
            location: []const u8,
            feed_id: usize,
            feed_updated_timestamp: ?i64,
            update_interval: usize,
            last_update: i64,
            last_modified_timestamp: ?i64,
        };

        const local_updates = try db.selectAll(DbResultLocal, allocator, self.db, Table.feed_update_local.selectAllWithLocation, .{});
        defer allocator.free(local_updates);

        if (local_updates.len == 0) {
            try cleanItems(self.db, allocator);
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
            l.info("Update feed (local): '{s}'", .{obj.location});
            const file = try std.fs.openFileAbsolute(obj.location, .{});
            defer file.close();
            var file_stat = try file.stat();
            if (!opts.force) {
                if (obj.last_modified_timestamp) |last_modified| {
                    const mtime_sec = @intCast(i64, @divFloor(file_stat.mtime, time.ns_per_s));
                    if (last_modified == mtime_sec) {
                        l.info("\tSkipping update: File hasn't been modified", .{});
                        continue;
                    }
                }
            }

            try contents.resize(0);
            try contents.ensureCapacity(file_stat.size);
            try file.reader().readAllArrayList(&contents, file_stat.size);
            var rss_feed = try parse.parse(allocator, contents.items);
            const mtime_sec = @intCast(i64, @divFloor(file_stat.mtime, time.ns_per_s));

            try db.update(self.db, update_local, .{
                mtime_sec,
                // where
                obj.feed_id,
            });

            if (!opts.force) {
                if (rss_feed.updated_timestamp != null and obj.feed_updated_timestamp != null and
                    rss_feed.updated_timestamp.? == obj.feed_updated_timestamp.?)
                {
                    l.info("\tSkipping update: Feed updated/pubDate hasn't changed", .{});
                    continue;
                }
            }

            try db.update(self.db, Table.feed.update_where_id, .{
                rss_feed.title,
                rss_feed.link,
                rss_feed.updated_raw,
                rss_feed.updated_timestamp,
                // where
                obj.feed_id,
            });

            try self.addItems(obj.feed_id, rss_feed.items);
            // TODO: remove extra feed items
            l.info("\tUpdate finished: '{s}'", .{obj.location});
        }
        try cleanItems(self.db, allocator);
    }

    pub fn deleteItemsById(self: Self, feed_id: usize) !void {
        const query =
            \\delete from item
            \\where id in
            \\	(select id from item
            \\		where feed_id = ?
            \\		order by pub_date_utc asc, created_at asc
            \\		limit (select max(count(feed_id) - ?, 0) from item where feed_id = ?)
            \\ )
        ;
        try db.delete(self.db, query, .{ feed_id, g.max_items_per_feed, feed_id });
    }
};

// TODO: see if there is good way to detect local file path or url
pub fn main() anyerror!void {
    std.log.info("Main run", .{});
    const base_allocator = std.heap.page_allocator;
    // const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const abs_location = "/media/hdd/code/feed_app/tmp/test.db_conn";
    // TODO: make default location somewhere in home directory
    // const abs_location = try makeFilePath(allocator, default_db_location);
    // const db_file = try std.fs.createFileAbsolute(
    //     abs_location,
    //     .{ .read = true, .truncate = false },
    // );

    // var db_conn = try db.create(abs_location);
    var db_conn = try db.createDb(allocator, null);
    // var db_conn = try db.createMemory();
    try db.setup(&db_conn);
    var db_struct = Db{ .conn = &db_conn, .allocator = allocator };

    var iter = process.args();
    _ = iter.skip();

    while (iter.next(allocator)) |arg_err| {
        const arg = try arg_err;
        if (mem.eql(u8, "add", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try cliAddFeed(&db_struct, value);
            } else {
                l.err("Subcommand add missing feed location", .{});
            }
        } else if (mem.eql(u8, "update", arg)) {
            const force = blk: {
                if (iter.next(allocator)) |value_err| {
                    const value = try value_err;
                    break :blk mem.eql(u8, "--all", value);
                }
                break :blk false;
            };
            try updateAllFeeds(allocator, &db_struct, .{ .force = force });
        } else if (mem.eql(u8, "clean", arg)) {
            try cleanItems(&db_struct, allocator);
        } else if (mem.eql(u8, "delete", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try deleteFeed(&db_struct, allocator, value);
            } else {
                l.err("Subcommand delete missing argument location", .{});
            }
        } else if (mem.eql(u8, "print", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                if (mem.eql(u8, "feeds", value)) {
                    try printFeeds(&db_struct, allocator);
                    return;
                }
            }

            try printAllItems(&db_struct, allocator);
        } else {
            l.err("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
}

pub fn newestFeedItems(items: []parse.Feed.Item, timestamp: i64) []parse.Feed.Item {
    for (items) |item, idx| {
        if (item.updated_timestamp) |item_date| {
            if (item_date <= timestamp) {
                return items[0..idx];
            }
        }
    }

    return items;
}

pub fn printFeeds(db_struct: *Db, allocator: *Allocator) !void {
    const Result = struct {
        title: []const u8,
        location: []const u8,
        link: ?[]const u8,
    };
    const query =
        \\SELECT title, location, link FROM feed
    ;
    var stmt = try db_struct.conn.prepare(query);
    defer stmt.deinit();
    const all_items = stmt.all(Result, allocator, .{}, .{}) catch |err| {
        l.warn("ERR: {s}\nFailed query:\n{s}", .{ db_struct.conn.getDetailedError().message, query });
        return err;
    };
    const writer = std.io.getStdOut().writer();
    try writer.print("There are {} feed(s)\n", .{all_items.len});

    const print_fmt =
        \\{s}
        \\  link: {s}
        \\  location: {s}
        \\
        \\
    ;

    for (all_items) |item| {
        const link = item.link orelse "<no-link>";
        try writer.print(print_fmt, .{ item.title, link, item.location });
    }
}

pub fn printAllItems(db_struct: *Db, allocator: *Allocator) !void {
    const Result = struct {
        title: []const u8,
        link: ?[]const u8,
        id: usize,
    };

    // most recently updated feed
    const most_recent_feeds_query =
        \\SELECT
        \\	title,
        \\  link,
        \\	id
        \\FROM
        \\	feed
    ;

    const most_recent_feeds = try db.selectAll(
        Result,
        allocator,
        db_struct.conn,
        most_recent_feeds_query,
        .{},
    );

    // grouped by feed_id
    const all_items_query =
        \\SELECT
        \\	title,
        \\	link,
        \\  feed_id
        \\FROM
        \\	item
        \\ORDER BY
        \\	feed_id DESC,
        \\	pub_date_utc DESC
    ;

    const all_items = try db.selectAll(
        Result,
        allocator,
        db_struct.conn,
        all_items_query,
        .{},
    );

    const writer = std.io.getStdOut().writer();

    for (most_recent_feeds) |feed| {
        const id = feed.id;
        const start_index = blk: {
            for (all_items) |item, idx| {
                if (item.id == id) break :blk idx;
            }
            break; // Should not happen
        };
        const feed_link = feed.link orelse "<no-link>";
        try writer.print("{s} - {s}\n", .{ feed.title, feed_link });
        for (all_items[start_index..]) |item| {
            if (item.id != id) break;
            const item_link = item.link orelse "<no-link>";
            try writer.print("  {s}\n  {s}\n\n", .{
                item.title,
                item_link,
            });
        }
    }
}

pub fn cliDeleteFeed(
    db_struct: *Db,
    allocator: *Allocator,
    location: []const u8,
) !void {
    const query =
        \\SELECT location, title, link, id FROM feed
        \\WHERE location LIKE ? OR link LIKE ? OR title LIKE ?
    ;
    const DbResult = struct {
        location: []const u8,
        title: []const u8,
        link: ?[]const u8,
        id: usize,
    };

    const search_term = try fmt.allocPrint(allocator, "%{s}%", .{location});
    defer allocator.free(search_term);

    const stdout = std.io.getStdOut();
    const results = try db.selectAll(DbResult, allocator, db_struct.conn, query, .{
        search_term,
        search_term,
        search_term,
    });
    if (results.len == 0) {
        try stdout.writer().print("Found no matches for '{s}' to delete.\n", .{location});
        return;
    }
    try stdout.writer().print("Found {} result(s):\n\n", .{results.len});
    for (results) |result, i| {
        const link = result.link orelse "<no-link>";
        try stdout.writer().print("{}. {s} | {s} | {s}\n", .{
            i + 1,
            result.title,
            link,
            result.location,
        });
    }
    try stdout.writer().print("\n", .{});
    try stdout.writer().print("Enter 'q' to quit.\n", .{});
    // TODO: flush stdin before or after reading it
    const stdin = std.io.getStdIn();
    var buf: [32]u8 = undefined;

    var delete_nr: usize = 0;
    while (true) {
        try stdout.writer().print("Enter number you want to delete? ", .{});
        const bytes = try stdin.read(&buf);
        if (buf[0] == '\n') break;

        if (bytes == 2 and buf[0] == 'q') return;

        if (fmt.parseUnsigned(usize, buf[0 .. bytes - 1], 10)) |nr| {
            if (nr >= 1 and nr <= results.len) {
                delete_nr = nr;
                break;
            }
            try stdout.writer().print("Entered number out of range. Try again.\n", .{});
            continue;
        } else |_| {
            try stdout.writer().print("Invalid number entered: '{s}'. Try again.\n", .{buf[0 .. bytes - 1]});
        }
    }

    const del_query =
        \\DELETE FROM feed WHERE id = ?;
    ;
    if (delete_nr > 0) {
        const result = results[delete_nr - 1];
        try deleteFeed(db_struct.conn, result.id);
        try stdout.writer().print("Deleted feed '{s}'\n", .{result.location});
    }
}

pub fn cleanItems(sql_db: *sql.Db, allocator: *Allocator) !void {
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

    const results = try db.selectAll(DbResult, allocator, sql_db, query, .{@as(usize, g.max_items_per_feed)});

    const del_query =
        \\DELETE FROM item
        \\WHERE id IN (SELECT id
        \\FROM item
        \\WHERE feed_id = ?
        \\ORDER BY pub_date_utc ASC, created_at DESC LIMIT ?)
    ;
    for (results) |r| {
        try db.delete(sql_db, del_query, .{ r.feed_id, r.count - g.max_items_per_feed });
    }
}

// TODO?: move FeedRequest creation inside fn and pass url as parameter
pub fn cliHandleRequest(allocator: *Allocator, start_req: http.FeedRequest) !http.FeedResponse {
    const stdout = std.io.getStdOut();
    var req = start_req;

    var resp = try http.resolveRequest(allocator, req);
    const max_tries = 3;
    var tries: usize = 0;

    // TODO: check status code
    while (tries < max_tries) {
        const old_resp = resp;
        l.warn("CONTENT: {}", .{resp.content_type});
        resp = try cliHandleResponse(allocator, resp);
        if (std.meta.eql(resp.url, old_resp.url)) break;
        tries += 1;
    }

    if (tries >= max_tries) {
        try stdout.writer().writeAll("Failed to get feed. Too many redirects.\n");
        return error.TooManyHttpTries;
    }

    return resp;
}

pub fn cliHandleResponse(allocator: *Allocator, resp: http.FeedResponse) !http.FeedResponse {
    const stdout = std.io.getStdOut();
    const stdin = std.io.getStdIn();
    switch (resp.content_type) {
        .xml, .xml_rss, .xml_atom => {},
        .html => {
            l.warn("Find links from html", .{});
            l.warn("LINKS {s}", .{resp.body.?});
            const page = try parse.Html.parseLinks(allocator, resp.body.?);

            var parse_link: parse.Html.Link = undefined;
            if (page.links.len == 0) {
                try stdout.writeAll("Could not find feed\n");
                return error.NoFeedFound;
            } else if (page.links.len == 1) {
                parse_link = page.links[0];
                // new request with new link/path
            } else {
                for (page.links) |link, i| {
                    const title = link.title orelse page.title orelse "<no title>";
                    const media_type = parse.Html.mediaTypeToString(link.media_type);
                    try stdout.writer().print("{d}. {s} [{s}]\n {s}\n\n", .{
                        i + 1,
                        title,
                        media_type,
                        // TODO: concat href with domain
                        link.href,
                    });
                }
                var buf: [64]u8 = undefined;
                while (true) {
                    try stdout.writer().print("Choose which feed to add. Enter number between 1 and {}: ", .{page.links.len});
                    const bytes = try stdin.reader().read(&buf);
                    // input without new line;
                    const input = buf[0 .. bytes - 1];
                    const nr = fmt.parseUnsigned(u16, input, 10) catch |err| {
                        try stdout.writer().print(
                            "Invalid number: '{s}'. Try again.\n",
                            .{input},
                        );
                        continue;
                    };
                    if (nr < 1 or nr > page.links.len) {
                        try stdout.writer().print(
                            "Number is out of range: '{s}'. Try again.\n",
                            .{input},
                        );
                        continue;
                    }

                    parse_link = page.links[nr - 1];
                    break;
                }
            }

            l.warn("Add feed '{s}'", .{parse_link.href});
            var url = http.Url{
                .protocol = resp.url.protocol,
                .domain = resp.url.domain,
                .path = parse_link.href,
            };
            const req = http.FeedRequest{ .url = url };
            return try http.resolveRequest(allocator, req);
        },
        .unknown => {
            try stdout.writer().writeAll("Unknown content type was returned\n");
            return error.UnknownHttpContent;
        },
    }

    return resp;
}

// Using arena allocator so all memory will be freed by arena allocator
pub fn cliAddFeed(db_struct: *Db, location_raw: []const u8) !void {
    const allocator = db_struct.allocator;
    const url_or_err = http.makeUrl(location_raw);

    // TODO: explore url/file detection
    if (url_or_err) |url| {
        var req = http.FeedRequest{ .url = url };

        // Also contains CLI prompt
        const resp = try cliHandleRequest(allocator, req);

        if (resp.body == null) {
            l.warn("Http response body is missing from request to '{s}'", .{location_raw});
            return;
        }

        const body = resp.body.?;

        const feed_data = blk: {
            switch (resp.content_type) {
                .xml_atom => {
                    break :blk try parse.Atom.parse(allocator, body);
                },
                .xml_rss => {
                    break :blk try parse.Rss.parse(allocator, body);
                },
                .xml => {
                    break :blk try parse.parse(allocator, body);
                },
                .html => unreachable, // cliHandleRequest fn should handles this
                .unknown => unreachable,
            }
        };

        // Adding to DB
        var location = try fmt.allocPrint(allocator, "{s}://{s}{s}", .{
            resp.url.protocol,
            resp.url.domain,
            resp.url.path,
        });

        try db_struct.insertFeed(.{
            .title = feed_data.title,
            .location = location,
            .link = feed_data.link,
            .updated_raw = feed_data.updated_raw,
            .updated_timestamp = feed_data.updated_timestamp,
        });

        // Unless something went wrong there has to be row
        const id = (try db_struct.getFeedId(location)) orelse return error.NoFeedWithLocation;

        try db.insert(db_struct.conn, Table.feed_update_http.insert ++ Table.feed_update_http.on_conflict_feed_id, .{
            id,
            resp.cache_control_max_age,
            resp.expires_utc,
            resp.last_modified_utc,
            resp.etag,
        });

        try addFeedItems(db_struct.conn, feed_data.items, id);
    } else |_| {
        const location = try makeFilePath(allocator, location_raw);
        const contents = try getFileContents(allocator, location);

        var feed_data = try parse.parse(allocator, contents);

        try db_struct.insertFeed(.{
            .title = feed_data.title,
            .location = location,
            .link = feed_data.link,
            .updated_raw = feed_data.updated_raw,
            .updated_timestamp = feed_data.updated_timestamp,
        });

        const id = (try db_struct.getFeedId(location)) orelse return error.NoFeedWithLocation;

        // TODO: get file last modified date
        const last_modified: i64 = 0;
        try db.insert(db_struct.conn, Table.feed_update_local.insert ++ Table.feed_update_local.on_conflict_feed_id, .{
            id, last_modified,
        });

        try addFeedItems(db_struct.conn, feed_data.items, id);
    }
    // try cleanItems(db_struct, allocator);
}

// TODO: Move to db.zig
pub fn getLatestAddedItemDateTimestamp(db_conn: *sql.Db, feed_id: usize) !?i64 {
    const query =
        \\SELECT pub_date_utc FROM item
        \\WHERE feed_id = ?
        \\ORDER BY pub_date_utc DESC
        \\LIMIT 1
    ;
    return try db.one(i64, db_conn, query, .{feed_id});
}

pub fn getFileContents(allocator: *Allocator, abs_path: []const u8) ![]const u8 {
    const file = try fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    return try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
}

test "getFileContents(): relative and absolute path" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const abs_path = "/media/hdd/code/feed_app/test/sample-rss-2.xml";
    const abs_content = try getFileContents(allocator, abs_path);
    const rel_path = "test/sample-rss-2.xml";
    const rel_content = try getFileContents(allocator, rel_path);

    assert(abs_content.len == rel_content.len);
}
