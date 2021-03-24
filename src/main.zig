const std = @import("std");
const sql = @import("sqlite");
const datetime = @import("datetime");
const http = @import("http.zig");
const Datetime = datetime.Datetime;
const timezones = datetime.timezones;
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
const db = @import("db.zig");
const Db = db.Db;
usingnamespace @import("queries.zig");

pub const log_level = std.log.Level.info;
const g = struct {
    const max_items_per_feed = 10;
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

    var db_conn = try db.create(abs_location);
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
                    break :blk mem.eql(u8, "--force", value);
                }
                break :blk false;
            };
            try updateFeeds(allocator, &db_struct, .{ .force = force });
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

        // try printAllItems(&db_conn, allocator);
    }
}

pub fn updateFeeds(allocator: *Allocator, db_struct: *Db, opts: struct { force: bool = false }) !void {
    @setEvalBranchQuota(2000);

    const DbResult = struct {
        location: []const u8,
        etag: ?[]const u8,
        feed_id: usize,
        update_interval: usize,
        last_update: i64,
        expires_utc: ?i64,
        last_modified_utc: ?i64,
        cache_control_max_age: ?i64,
    };

    const feed_updates = try db.selectAll(DbResult, allocator, db_struct.conn, Table.feed_update.selectAllWithLocation, .{});
    var indexes = try ArrayList(usize).initCapacity(allocator, feed_updates.len);

    const current_time = std.time.timestamp();

    for (feed_updates) |obj, i| {
        const check_date: i64 = blk: {
            if (obj.cache_control_max_age) |sec| {
                // Uses cache_control_max_age, last_update
                break :blk obj.last_update + sec;
            }
            break :blk obj.last_update + @intCast(i64, obj.update_interval);
        };

        if (!opts.force) {
            if (obj.expires_utc != null and check_date > obj.expires_utc.?) {
                continue;
            } else if (check_date > current_time) {
                continue;
            }
        }
        try indexes.append(i);
    }

    for (indexes.items) |i| {
        l.warn("item", .{});
        const obj = feed_updates[i];
        // if (true) continue;
        const url_or_err = http.makeUrl(obj.location);

        if (url_or_err) |url| {
            if (true) continue;

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
            if (resp.body == null) {
                l.warn("Empty HTTP request body. Skipping updating.", .{});
                continue;
            }

            const body = resp.body.?;

            // TODO: fix
            const rss_feed = try parse.Feed.init(allocator, obj.location, body);

            // TODO: update last_update field
            try update(db_conn, Table.feed_update.update_id, .{
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
                try update(db_conn, Table.feed.update_where_id, .{
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
                    db_conn,
                    Table.item.select_feed_latest,
                    .{obj.feed_id},
                );

                const items = if (latest_item_date) |latest_date|
                    newestFeedItems(rss_feed.items, latest_date)
                else
                    rss_feed.items;

                try addFeedItems(db_struct.conn, items, obj.feed_id);
            }
        } else |_| {
            l.warn("Check local file feed", .{});
            // TODO?: file's last_modified date
            const contents = getLocalFileContents(allocator, obj.location) catch |err| switch (err) {
                std.fs.File.OpenError.FileNotFound => {
                    l.err("Could not locate local feed (file) at: '{s}'", .{obj.location});
                    continue;
                },
                else => return err,
            };
            defer allocator.free(contents);

            var rss_feed = try parse.parse(allocator, contents);

            try db.update(db_struct.conn, Table.feed_update.update_id, .{
                null,
                null,
                null, // TODO: when file was last modified
                null,
                // where
                obj.feed_id,
            });

            const need_update = true;
            if (need_update) {
                l.warn("Update local feed", .{});
                try db.update(db_struct.conn, Table.feed.update_where_id, .{
                    rss_feed.title,
                    rss_feed.link,
                    rss_feed.updated_raw,
                    rss_feed.updated_timestamp,
                    rss_feed.last_item_timestamp,
                    // where
                    obj.feed_id,
                });

                // get newest feed's item updated_timestamp
                const latest_item_date = try db.one(
                    i64,
                    db_struct.conn,
                    Table.item.select_feed_latest,
                    .{obj.feed_id},
                );

                const items = if (latest_item_date) |latest_date|
                    newestFeedItems(rss_feed.items, latest_date)
                else
                    rss_feed.items;

                try addFeedItems(db_struct.conn, items, obj.feed_id);
            }
        }
        l.warn("item end", .{});
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
        link: ?[]const u8,
    };
    // NOTE: in case of DESC pub_date_utc null values got to the end of table
    const query =
        \\SELECT title, link FROM feed
        \\ORDER BY added_at ASC
    ;
    var stmt = try db_struct.conn.prepare(query);
    defer stmt.deinit();
    const all_items = stmt.all(Result, allocator, .{}, .{}) catch |err| {
        l.warn("ERR: {s}\nFailed query:\n{s}", .{ db_struct.conn.getDetailedError().message, query });
        return err;
    };
    const writer = std.io.getStdOut().writer();
    try writer.print("There are {} feed(s)\n", .{all_items.len});

    for (all_items) |item| {
        const link = item.link orelse "<no-link>";
        try writer.print("{s} - {s}\n\n", .{ item.title, link });
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
        \\ORDER BY
        \\	last_item_timestamp DESC
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

pub fn deleteFeed(
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
        try db.delete(db_struct.conn, del_query, .{result.id});
        try stdout.writer().print("Deleted feed '{s}'\n", .{result.location});
    }
}

pub fn cleanItems(db_struct: *Db, allocator: *Allocator) !void {
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

    const results = try db.selectAll(DbResult, allocator, db_struct.conn, query, .{@as(usize, g.max_items_per_feed)});

    const del_query =
        \\DELETE FROM item
        \\WHERE id IN (SELECT id
        \\FROM item
        \\WHERE feed_id = ?
        \\ORDER BY pub_date_utc ASC, created_at DESC LIMIT ?)
    ;
    for (results) |r| {
        try db.delete(db_struct.conn, del_query, .{ r.feed_id, r.count - g.max_items_per_feed });
    }
}

test "active" {
    const input = "./test/sample-rss-2.xml";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    var db_conn = try memoryDb();
    try dbSetup(&db_conn);

    // try cliAddFeed(&db_conn, allocator, input);
    // try updateFeeds(allocator, &db_conn);

    // const page = try parse.Html.parseLinks(allocator, @embedFile("../test/lobste.rs.html"));

    const url_str = "https://www.thecrazyprogrammer.com/feed";
    // const url = try http.makeUrl(url_str);
    // const url = try http.makeUrl("https://lobste.rs");
    // var req = http.FeedRequest{ .url = url };
    const resp = try cliAddFeed(&db_conn, allocator, url_str);
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

    if (url_or_err) |url| {
        var req = http.FeedRequest{ .url = url };
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
            .last_item_timestamp = feed_data.last_item_timestamp,
        });

        // Unless something went wrong there has to be row
        const id = (try db_struct.getFeedId(location)) orelse return error.NoFeedWithLocation;

        try db.insert(db_struct.conn, Table.feed_update.insert ++ Table.feed_update.on_conflict_feed_id, .{
            id,
            resp.cache_control_max_age,
            resp.expires_utc,
            resp.last_modified_utc,
            resp.etag,
        });

        try addFeedItems(db_struct.conn, feed_data.items, id);
    } else |_| {
        const location = try makeFilePath(allocator, location_raw);
        const contents = try getLocalFileContents(allocator, location);

        var feed_data = try parse.parse(allocator, contents);

        try db_struct.insertFeed(.{
            .title = feed_data.title,
            .location = location,
            .link = feed_data.link,
            .updated_raw = feed_data.updated_raw,
            .updated_timestamp = feed_data.updated_timestamp,
            .last_item_timestamp = feed_data.last_item_timestamp,
        });

        const id = (try db_struct.getFeedId(location)) orelse return error.NoFeedWithLocation;

        // TODO: file last modified date
        const last_modified = 0;
        try db.insert(db_struct.conn, Table.feed_update.insert ++ Table.feed_update.on_conflict_feed_id, .{
            id, null, null, last_modified, null,
        });

        try addFeedItems(db_struct.conn, feed_data.items, id);
    }
}

pub const FeedUpdate = struct {
    const Self = @This();
    allocator: *Allocator,
    db_conn: *sql.Db,

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
        var stmt = try feed_update.db_conn.prepare(Table.feed_update.selectAll);
        defer stmt.deinit();
        return stmt.all(Raw, feed_update.allocator, .{}, .{}) catch |err| {
            l.warn("FeedUpdate.selectAll() failed. ERR: {s}\n", .{
                feed_update.db_conn.getDetailedError().message,
            });
            return err;
        };
    }
};

pub fn addFeedItems(db_conn: *sql.Db, feed_items: []parse.Feed.Item, feed_id: usize) !void {
    const len = std.math.min(feed_items.len, g.max_items_per_feed);
    for (feed_items[0..len]) |it| {
        if (it.id) |_| {
            try db.insert(
                db_conn,
                Table.item.insert ++ Table.item.on_conflict_guid,
                .{ feed_id, it.title, it.link, it.id, it.updated_raw, it.updated_timestamp },
            );
        } else if (it.link) |_| {
            // TODO: use it.link as link.id
            try db.insert(
                db_conn,
                Table.item.insert ++ Table.item.on_conflict_link,
                .{ feed_id, it.title, it.link, it.id, it.updated_raw, it.updated_timestamp },
            );
        } else if (it.updated_raw != null and
            try db.one(bool, db_conn, Table.item.has_item, .{ feed_id, it.updated_timestamp }) != null)
        {
            // Updates row if it matches feed_id and updated_timestamp
            try db.update(db_conn, Table.item.update_without_guid_and_link, .{
                // set column values
                it.title, it.link,              it.id,
                // where
                feed_id,  it.updated_timestamp,
            });
        } else {
            try db.insert(
                db_conn,
                Table.item.insert,
                .{ feed_id, it.title, it.link, it.id, it.updated_raw, it.updated_timestamp },
            );
        }
    }
}

const Item = struct {
    const Self = @This();
    allocator: *Allocator,
    db_conn: *sql.Db,

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
        var all = try item.db_conn.prepare(Table.item.select_all);
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

pub fn addFeed(db_conn: Db, rss_feed: parse.Feed) !usize {
    try insert(db_conn, Table.feed.insert ++ Table.feed.on_conflict_location, .{
        rss_feed.title,
        rss_feed.link,
        rss_feed.location,
        rss_feed.pub_date,
        rss_feed.pub_date_utc,
        rss_feed.last_build_date,
        rss_feed.last_build_date_utc,
    });

    // Just inserted feed, it has to exist
    const id = (try one(
        usize,
        db_conn,
        Table.feed.select_id ++ Table.feed.where_location,
        .{rss_feed.info.location},
    )).?;
    return id;
}

pub const Feed = struct {
    const Self = @This();
    allocator: *Allocator,
    db_conn: *sql.Db,

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

    pub fn init(allocator: *Allocator, db_conn: *sql.Db) Self {
        return Self{
            .allocator = allocator,
            .db_conn = db_conn,
        };
    }

    pub fn select(feed: Self) !?Raw {
        const db_conn = feed.db_conn;
        const allocator = feed.allocator;
        return db_conn.oneAlloc(Raw, allocator, Table.feed.select, .{}, .{}) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select,
                db_conn.getDetailedError().message,
            });
            return err;
        };
    }

    pub fn selectLocation(feed: Self, location: []const u8) !?Raw {
        const db_conn = feed.db_conn;
        const allocator = feed.allocator;
        return db_conn.oneAlloc(
            Raw,
            allocator,
            Table.feed.select ++ Table.feed.where_location,
            .{},
            .{location},
        ) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select ++ Table.feed.where_location,
                db_conn.getDetailedError().message,
            });
            return err;
        };
    }
};

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

    pub fn select(allocator: *Allocator, db_conn: *sql.Db) !?Setting {
        return db_conn.oneAlloc(Setting, allocator, Table.setting.select, .{}, .{}) catch |err| {
            l.warn("Failed to get setting. ERR: {s}\n", .{db_conn.getDetailedError().message});
            return err;
        };
    }
};

// test "verifyDbTables" {
//     var allocator = testing.allocator;
//     var db_conn = try memoryDb();

//     try dbSetup(&db_conn);
//     const result = verifyDbTables(&db_conn);
//     assert(result);
//     const setting = (try Setting.select(allocator, &db_conn)).?;
//     assert(1 == setting.version);
// }
