const std = @import("std");
const sql = @import("sqlite");
const datetime = @import("datetime");
const http = @import("http.zig");
const Datetime = datetime.Datetime;
const timezones = datetime.timezones;
const rss = @import("rss.zig");
const parse = @import("parse.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const process = std.process;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const l = std.log;
usingnamespace @import("queries.zig");

pub const log_level = std.log.Level.info;
const g = struct {
    const max_items_per_feed = 10;
};

// Sqlite
// Do upsert with update and insert:
// https://stackoverflow.com/questions/15277373/sqlite-upsert-update-or-insert/38463024#38463024
// TODO: find domain's rss feeds
// 		html link application+xml
// 		for popular platforms can guess url. wordpress: /feed/
// TODO?: PRAGMA schema.user_version = integer ;
// TODO: implement downloading a file
// TODO: see if there is good way to detect local file path or url

const default_db_location = "./tmp/test.db";
pub fn main() anyerror!void {
    std.log.info("Main run", .{});
    const base_allocator = std.heap.page_allocator;
    // const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const abs_location = try makeFilePath(allocator, default_db_location);
    const db_file = try std.fs.createFileAbsolute(
        abs_location,
        .{ .read = true, .truncate = false },
    );

    // TODO: replace memory db with file db
    // var db = try memoryDb();
    // const db_loc: [:0]const u8 = "/media/hdd/code/feed_inbox/tmp/test.db";
    var db = try createDb("/media/hdd/code/feed_inbox/tmp/test.db");
    try dbSetup(&db);

    var iter = process.args();
    _ = iter.skip();

    while (iter.next(allocator)) |arg_err| {
        const arg = try arg_err;
        if (mem.eql(u8, "add", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try cliAddFeed(&db, allocator, value);
            } else {
                l.err("Subcommand add missing feed location", .{});
            }
        } else if (mem.eql(u8, "update", arg)) {
            try updateFeeds(allocator, &db);
        } else if (mem.eql(u8, "clean", arg)) {
            try cleanItems(&db, allocator);
        } else if (mem.eql(u8, "delete", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try deleteFeed(&db, allocator, value);
            } else {
                l.err("Subcommand delete missing argument location", .{});
            }
        } else if (mem.eql(u8, "print", arg)) {
            try printFeeds(&db, allocator);
        } else {
            l.err("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }

        // try printAllItems(&db, allocator);
    }
}

pub fn updateFeeds(allocator: *Allocator, db: *sql.Db) !void {
    @setEvalBranchQuota(2000);

    const DbResult = struct {
        location: []const u8,
        etag: ?[]const u8,
        feed_id: usize,
        update_interval: usize,
        ttl: ?usize,
        last_update: i64,
        expires_utc: ?i64,
        last_modified_utc: ?i64,
        cache_control_max_age: ?i64,
        pub_date_utc: ?i64,
        last_build_date_utc: ?i64,
    };

    const feed_updates = try selectAll(DbResult, allocator, db, Table.feed_update.selectAllWithLocation, .{});
    var indexes = try ArrayList(usize).initCapacity(allocator, feed_updates.len);

    const current_time = std.time.timestamp();

    for (feed_updates) |obj, i| {
        const check_date: i64 = blk: {
            if (obj.ttl) |min| {
                // Uses ttl, last_build_date_utc || last_update
                const base_date = if (obj.last_build_date_utc) |d| d else obj.last_update;
                break :blk base_date + (std.time.s_per_min * @intCast(i64, min));
            } else if (obj.cache_control_max_age) |sec| {
                // Uses cache_control_max_age, last_update
                break :blk obj.last_update + sec;
            }
            break :blk obj.last_update + @intCast(i64, obj.update_interval);
        };

        if (obj.expires_utc) |expire| {
            if (check_date < expire) {
                continue;
            }
        } else if (check_date < current_time) {
            continue;
        }

        try indexes.append(i);
    }

    for (indexes.items) |i| {
        const obj = feed_updates[i];
        if (true) continue;
        const url_or_err = http.makeUrl(obj.location);

        if (url_or_err) |url| {
            l.warn("Feed's HTTP request", .{});
            var req = http.FeedRequest{ .url = url };
            if (obj.etag) |etag| {
                req.etag = etag;
            } else if (obj.last_modified_utc) |last_modified_utc| {
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
                req.last_modified = date_str;
            }

            const resp = try http.resolveRequest(allocator, req);

            // No new content if body is null
            if (resp.body == null) continue;

            const body = resp.body.?;

            const rss_feed = try rss.Feed.init(allocator, obj.location, body);
            // TODO: update last_updat field
            try update(db, Table.feed_update.update_id, .{
                rss_feed.info.ttl,
                resp.cache_control_max_age,
                resp.expires_utc,
                resp.last_modified_utc,
                resp.etag,
                // where
                obj.feed_id,
            });

            const has_changed = rss_feed.info.pub_date_utc == null or
                !std.meta.eql(obj.pub_date_utc, rss_feed.info.pub_date_utc) or
                !std.meta.eql(obj.last_build_date_utc, rss_feed.info.last_build_date_utc);

            if (has_changed) {
                const location: []const u8 = try fmt.allocPrint(allocator, "{s}://{s}{s}", .{
                    resp.url.protocol,
                    resp.url.domain,
                    resp.url.path,
                });
                // feed update
                try update(db, Table.feed.update_where_id, .{
                    rss_feed.info.title,
                    rss_feed.info.link,
                    location,
                    rss_feed.info.pub_date,
                    rss_feed.info.pub_date_utc,
                    rss_feed.info.last_build_date,
                    rss_feed.info.last_build_date_utc,
                    // where
                    obj.feed_id,
                });

                // get newest feed's item pub_date
                const latest_item_date = try one(
                    i64,
                    db,
                    Table.item.select_feed_latest,
                    .{obj.feed_id},
                );

                const items = if (latest_item_date) |latest_date|
                    newestFeedItems(rss_feed.items, latest_date)
                else
                    rss_feed.items;

                try addFeedItems(db, items, obj.feed_id);
            }
        } else |_| {
            l.warn("Check local file feed", .{});
            // TODO?: file's last_modified date
            const contents = getLocalFileContents(allocator, obj.location) catch |err| switch (err) {
                std.fs.File.OpenError.FileNotFound => {
                    l.err("Could not locate local feed (file) at: '{}'", .{obj.location});
                    continue;
                },
                else => return err,
            };
            defer allocator.free(contents);

            var rss_feed = try rss.Feed.init(allocator, obj.location, contents);
            defer rss_feed.deinit();
            const need_update = rss_feed.info.pub_date_utc == null or
                !std.meta.eql(rss_feed.info.pub_date_utc, obj.pub_date_utc);
            if (need_update) {
                l.warn("Update local feed", .{});
                try update(db, Table.feed.update_id, .{
                    rss_feed.info.title,
                    rss_feed.info.link,
                    rss_feed.info.pub_date,
                    rss_feed.info.pub_date_utc,
                    rss_feed.info.last_build_date,
                    rss_feed.info.last_build_date_utc,
                    // where
                    obj.feed_id,
                });

                // feed update
                try update(db, Table.feed.update_id, .{
                    rss_feed.info.title,
                    rss_feed.info.link,
                    rss_feed.info.pub_date,
                    rss_feed.info.pub_date_utc,
                    rss_feed.info.last_build_date,
                    rss_feed.info.last_build_date_utc,
                    // where
                    obj.feed_id,
                });

                // get newest feed's item pub_date
                const latest_item_date = try one(
                    i64,
                    db,
                    Table.item.select_feed_latest,
                    .{obj.feed_id},
                );

                const items = if (latest_item_date) |latest_date|
                    newestFeedItems(rss_feed.items, latest_date)
                else
                    rss_feed.items;

                try addFeedItems(db, items, obj.feed_id);
            }
        }
    }
}

pub fn newestFeedItems(items: []rss.Item, timestamp: i64) []rss.Item {
    for (items) |item, idx| {
        if (item.pub_date_utc) |item_date| {
            if (item_date <= timestamp) {
                return items[0..idx];
            }
        }
    }

    return items;
}

pub fn select(comptime T: type, allocator: *Allocator, db: *sql.Db, comptime query: []const u8, opts: anytype) !?T {
    return db.oneAlloc(T, allocator, query, .{}, opts) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn selectAll(
    comptime T: type,
    allocator: *Allocator,
    db: *sql.Db,
    comptime query: []const u8,
    opts: anytype,
) ![]T {
    var stmt = db.prepare(query) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
    defer stmt.deinit();
    return stmt.all(T, allocator, .{}, opts) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn printFeeds(db: *sql.Db, allocator: *Allocator) !void {
    const Result = struct {
        title: []const u8,
        link: ?[]const u8,
    };
    // NOTE: in case of DESC pub_date_utc null values got to the end of table
    const query =
        \\SELECT title, link FROM feed
        \\ORDER BY created_at ASC
    ;
    var stmt = try db.prepare(query);
    defer stmt.deinit();
    const all_items = stmt.all(Result, allocator, .{}, .{}) catch |err| {
        l.warn("ERR: {s}\nFailed query:\n{}", .{ db.getDetailedError().message, query });
        return err;
    };
    const writer = std.io.getStdOut().writer();
    try writer.print("count: {}\n", .{all_items.len});

    for (all_items) |item| {
        const link = item.link orelse "<no-link>";
        try writer.print("{s}\n{s}\n\n", .{ item.title, link });
    }
}

pub fn printAllItems(db: *sql.Db, allocator: *Allocator) !void {
    const Result = struct {
        title: []const u8,
        link: ?[]const u8,
    };
    // NOTE: in case of DESC pub_date_utc null values got to the end of table
    const query =
        \\SELECT title, link FROM item
        \\ORDER BY pub_date_utc DESC, created_at ASC
    ;
    var stmt = try db.prepare(query);
    defer stmt.deinit();
    const all_items = stmt.all(Result, allocator, .{}, .{}) catch |err| {
        l.warn("ERR: {s}\nFailed query:\n{}", .{ db.getDetailedError().message, query });
        return err;
    };
    const writer = std.io.getStdOut().writer();
    try writer.print("count: {}\n", .{all_items.len});

    for (all_items) |item| {
        const link = item.link orelse "<no-link>";
        try writer.print("{s}\n{s}\n\n", .{ item.title, link });
    }
}

pub fn deleteFeed(
    db: *sql.Db,
    allocator: *Allocator,
    location: []const u8,
) !void {
    const query =
        \\SELECT location, id FROM feed WHERE location LIKE ?
    ;
    const DbResult = struct {
        location: []const u8,
        id: usize,
    };

    const search_term = try fmt.allocPrint(allocator, "%{s}%", .{"e"});
    defer allocator.free(search_term);

    const del_query =
        \\DELETE FROM feed WHERE id = ?
    ;
    const stdout = std.io.getStdOut();
    const results = try selectAll(DbResult, allocator, db, query, .{search_term});
    if (results.len == 0) {
        try stdout.writer().print("Found no matches for '{s}' to delete.\n", .{location});
        return;
    }
    try stdout.writer().print("Found {} result(s):\n\n", .{results.len});
    for (results) |result, i| {
        try stdout.writer().print("{}. {s}\n", .{ i + 1, result.location });
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

    if (delete_nr > 0) {
        const result = results[delete_nr - 1];
        try delete(db, del_query, .{result.id});
        try stdout.writer().print("Deleted feed '{s}'\n", .{result.location});
    }
}

pub fn cleanItems(db: *sql.Db, allocator: *Allocator) !void {
    const query =
        \\select
        \\  feed_id, count(feed_id) as count
        \\from item
        \\group by feed_id
        \\having count(feed_id) > ?{usize}
    ;

    const DbResult = struct {
        feed_id: usize,
        count: usize,
    };

    const results = try selectAll(DbResult, allocator, db, query, .{@as(usize, g.max_items_per_feed)});

    const DbDelResult = struct {
        id: usize,
        feed_id: usize,
        created_at: i64,
        pub_date_utc: ?i64,
    };

    const del_query =
        \\delete from item
        \\where id in (select id
        \\from item
        \\where feed_id = ?
        \\order by pub_date_utc ASC, created_at desc LIMIT ?)
    ;
    for (results) |r| {
        try delete(db, del_query, .{ r.feed_id, r.count - g.max_items_per_feed });
    }
}

test "active" {
    const input = "./test/sample-rss-2.xml";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    var db = try memoryDb();
    try dbSetup(&db);

    // try cliAddFeed(&db, allocator, input);
    // try updateFeeds(allocator, &db);

    // const page = try parse.findFeedLinks(allocator, @embedFile("../test/lobste.rs.html"));

    const url_str = "https://www.thecrazyprogrammer.com/feed";
    // const url = try http.makeUrl(url_str);
    // const url = try http.makeUrl("https://lobste.rs");
    // var req = http.FeedRequest{ .url = url };
    const resp = try cliAddFeed(&db, allocator, url_str);
}

// TODO?: move FeedRequest creation inside fn and pass url as parameter
pub fn cliHandleRequest(allocator: *Allocator, start_req: http.FeedRequest) !http.FeedResponse {
    const stdout = std.io.getStdOut();
    var req = start_req;

    var resp = try http.resolveRequest(allocator, req);
    const max_tries = 3;
    var tries: usize = 0;

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
        .xml => {},
        .html => {
            l.warn("Find links from html", .{});
            l.warn("LINKS {s}", .{resp.body.?});
            const page = try parse.findFeedLinks(allocator, resp.body.?);

            var parse_link: parse.Link = undefined;
            if (page.links.len == 0) {
                try stdout.writeAll("Could not find feed\n");
                return error.NoFeedFound;
            } else if (page.links.len == 1) {
                parse_link = page.links[0];
                // new request with new link/path
            } else {
                for (page.links) |link, i| {
                    const title = link.title orelse page.title orelse "<no title>";
                    const media_type = parse.mediaTypeToString(link.media_type);
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
pub fn cliAddFeed(db: *sql.Db, allocator: *Allocator, location_raw: []const u8) !void {
    const url_or_err = http.makeUrl(location_raw);

    if (url_or_err) |url| {
        var req = http.FeedRequest{ .url = url };
        const resp = try cliHandleRequest(allocator, req);

        if (resp.body == null) {
            l.warn("Http response body is missing from request to '{}'", .{location_raw});
            return;
        }

        const body = resp.body.?;

        var location = try fmt.allocPrint(allocator, "{s}://{s}{s}", .{
            resp.url.protocol,
            resp.url.domain,
            resp.url.path,
        });
        var rss_feed = try rss.Feed.init(allocator, location, body);

        const feed_id = try addFeed(db, rss_feed);

        try insert(db, Table.feed_update.insert ++ Table.feed_update.on_conflict_feed_id, .{
            feed_id,
            rss_feed.info.ttl,
            resp.cache_control_max_age,
            resp.expires_utc,
            resp.last_modified_utc,
            resp.etag,
        });

        try addFeedItems(db, rss_feed.items, feed_id);
    } else |_| {
        const location = try makeFilePath(allocator, location_raw);
        const contents = try getLocalFileContents(allocator, location);

        var rss_feed = try rss.Feed.init(allocator, location, contents);

        const feed_id = try addFeed(db, rss_feed);

        try insert(db, Table.feed_update.insert ++ Table.feed_update.on_conflict_feed_id, .{
            feed_id, rss_feed.info.ttl, null, null, null, null,
        });

        try addFeedItems(db, rss_feed.items, feed_id);
    }
}

pub fn insert(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    @setEvalBranchQuota(2000);

    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn update(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn delete(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

// Non-alloc select query that returns one or none rows
pub fn one(comptime T: type, db: *sql.Db, comptime query: []const u8, args: anytype) !?T {
    return db.one(T, query, .{}, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub const FeedUpdate = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    const Raw = struct {
        etag: ?[]const u8,
        feed_id: usize,
        update_interval: usize,
        last_update: i64,
        ttl: ?usize,
        last_build_date_utc: ?i64,
        expires_utc: ?i64,
        last_modified_utc: ?i64,
        cache_control_max_age: ?i64,
    };

    pub fn selectAll(feed_update: Self) ![]Raw {
        var stmt = try feed_update.db.prepare(Table.feed_update.selectAll);
        defer stmt.deinit();
        return stmt.all(Raw, feed_update.allocator, .{}, .{}) catch |err| {
            l.warn("FeedUpdate.selectAll() failed. ERR: {s}\n", .{
                feed_update.db.getDetailedError().message,
            });
            return err;
        };
    }
};

pub fn addFeedItems(db: *sql.Db, feed_items: []rss.Item, feed_id: usize) !void {
    const len = std.math.min(feed_items.len, g.max_items_per_feed);
    for (feed_items[0..len]) |it| {
        if (it.guid) |_| {
            try insert(
                db,
                Table.item.insert ++ Table.item.on_conflict_guid,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        } else if (it.link) |_| {
            try insert(
                db,
                Table.item.insert ++ Table.item.on_conflict_link,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        } else if (it.pub_date != null and
            try one(bool, db, Table.item.has_item, .{ feed_id, it.pub_date_utc }) != null)
        {
            // Updates row if it matches feed_id and pub_date_utc
            try update(db, Table.item.update_without_guid_and_link, .{
                // set column values
                it.title, it.link,         it.guid,
                // where
                feed_id,  it.pub_date_utc,
            });
        } else {
            try insert(
                db,
                Table.item.insert,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        }
    }
}

const Item = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    const Raw = struct {
        title: []const u8,
        link: []const u8,
        pub_date: []const u8,
        created_at: []const u8,
        // TODO: add guid: ?[]const u8
        // TODO: add pub_date_utc: ?i64
        feed_id: usize,
        id: usize,
    };

    pub fn deinitRaw(link: Self, raw: ?Raw) void {
        if (raw) |r| {
            link.allocator.free(r.title);
            link.allocator.free(r.link);
            link.allocator.free(r.pub_date);
            link.allocator.free(r.created_at);
        }
    }

    pub fn selectAll(item: Self) ![]Raw {
        var all_items = ArrayList(Raw).init(item.allocator);
        errdefer all_items.deinit();
        var all = try item.db.prepare(Table.item.select_all);
        defer all.deinit();
        var iter = try all.iterator(Raw, .{});
        while (try iter.nextAlloc(item.allocator, .{})) |link_row| {
            try all_items.append(link_row);
        }
        return all_items.toOwnedSlice();
    }
};

// location has to be absolute
pub fn getLocalFileContents(allocator: *Allocator, abs_location: []const u8) ![]const u8 {
    const local_file = try std.fs.openFileAbsolute(abs_location, .{});
    defer local_file.close();
    var file_stat = try local_file.stat();

    return try local_file.reader().readAllAlloc(allocator, file_stat.size);
}

pub fn addFeed(db: *sql.Db, rss_feed: rss.Feed) !usize {
    try insert(db, Table.feed.insert ++ Table.feed.on_conflict_location, .{
        rss_feed.info.title,
        rss_feed.info.link,
        rss_feed.info.location,
        rss_feed.info.pub_date,
        rss_feed.info.pub_date_utc,
        rss_feed.info.last_build_date,
        rss_feed.info.last_build_date_utc,
    });

    // Just inserted feed, it has to exist
    const id = (try one(
        usize,
        db,
        Table.feed.select_id ++ Table.feed.where_location,
        .{rss_feed.info.location},
    )).?;
    return id;
}

pub const Feed = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    pub const Raw = struct {
        title: []const u8,
        link: []const u8,
        location: []const u8,
        id: usize,
        pub_date_utc: ?i64,
    };

    pub fn deinitRaw(feed: Self, raw: ?Raw) void {
        if (raw) |r| {
            feed.allocator.free(r.title);
            feed.allocator.free(r.link);
            feed.allocator.free(r.location);
        }
    }

    pub fn init(allocator: *Allocator, db: *sql.Db) Self {
        return Self{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn select(feed: Self) !?Raw {
        const db = feed.db;
        const allocator = feed.allocator;
        return db.oneAlloc(Raw, allocator, Table.feed.select, .{}, .{}) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select,
                db.getDetailedError().message,
            });
            return err;
        };
    }

    pub fn selectLocation(feed: Self, location: []const u8) !?Raw {
        const db = feed.db;
        const allocator = feed.allocator;
        return db.oneAlloc(
            Raw,
            allocator,
            Table.feed.select ++ Table.feed.where_location,
            .{},
            .{location},
        ) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select ++ Table.feed.where_location,
                db.getDetailedError().message,
            });
            return err;
        };
    }
};

pub fn memoryDb() !sql.Db {
    var db: sql.Db = undefined;
    try db.init(.{
        .mode = sql.Db.Mode.Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
        // .threading_mode = .SingleThread,
    });
    return db;
}

pub fn createDb(abs_loc: [:0]const u8) !sql.Db {
    var db: sql.Db = undefined;
    try db.init(.{
        .mode = sql.Db.Mode{ .File = abs_loc },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    return db;
}

fn dbSetup(db: *sql.Db) !void {
    _ = try db.pragma(usize, .{}, "foreign_keys", .{"1"});

    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasDecl(decl.data.Type, "create")) {
            const sql_create = @field(decl.data.Type, "create");
            db.exec(sql_create, .{}) catch |err| {
                l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, sql_create });
                return err;
            };
        }
    }

    const version: usize = 1;
    try insert(db, Table.setting.insert, .{version});
}

pub fn verifyDbTables(db: *sql.Db) bool {
    const select_table = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;";
    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasField(decl.data.Type, "create")) {
            const row = one(usize, db, select_table, .{decl.name});
            if (row == null) return false;
            break;
        }
    }

    return true;
}

pub fn makeFilePath(allocator: *Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try mem.dupe(allocator, u8, path);
    }
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
}

const Setting = struct {
    version: usize,

    pub fn select(allocator: *Allocator, db: *sql.Db) !?Setting {
        return db.oneAlloc(Setting, allocator, Table.setting.select, .{}, .{}) catch |err| {
            l.warn("Failed to get setting. ERR: {s}\n", .{db.getDetailedError().message});
            return err;
        };
    }
};

// test "verifyDbTables" {
//     var allocator = testing.allocator;
//     var db = try memoryDb();

//     try dbSetup(&db);
//     const result = verifyDbTables(&db);
//     assert(result);
//     const setting = (try Setting.select(allocator, &db)).?;
//     assert(1 == setting.version);
// }
