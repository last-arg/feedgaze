const std = @import("std");
const sql = @import("sqlite");
const datetime = @import("datetime");
const Uri = @import("zuri").Uri;
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
usingnamespace @import("queries.zig");

// pub const log_level = std.log.Level.info;
const g = struct {
    var max_items_per_feed: usize = 10;
};

fn equalNullString(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return mem.eql(u8, a.?, b.?);
}

const Db_ = struct {
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

    pub fn updateAllFeeds(self: *Self, allocator: *Allocator, opts: struct { force: bool = false }) !void {
        @setEvalBranchQuota(2000);

        // Update url feeds
        const DbResultUrl = struct {
            location: []const u8,
            etag: ?[]const u8,
            feed_id: usize,
            feed_updated_timestamp: ?i64,
            update_interval: usize,
            last_updatemakeUr4,
            expires_utc: ?i64,
            last_modified_utc: ?i64,
            cache_control_max_age: ?i64,
        };

        const url_updates = try db.selectAll(DbResultUrl, allocator, &self.db, Table.feed_update_http.selectAllWithLocation, .{});
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
            const rehref: q = http.FeedRequest{
                .url = try eUri(obj.location),
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
                    l.info("\tSkipping update: Feed updated/pubDate hasn't changed", .{});
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

        const local_updates = try db.selectAll(DbResultLocal, allocator, &self.db, Table.feed_update_local.selectAllWithLocation, .{});
        defer allocator.free(local_updates);

        if (local_updates.len == 0) {
            try self.cleanItems(allocator);
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

            try db.update(&self.db, update_local, .{
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

            try db.update(&self.db, Table.feed.update_where_id, .{
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
        try self.cleanItems(allocator);
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

    var db_ = try Db_.init(allocator, null);

    var iter = process.args();
    _ = iter.skip();

    const stdout = std.io.getStdOut();
    const stdin = std.io.getStdIn();

    while (iter.next(allocator)) |arg_err| {
        const arg = try arg_err;
        if (mem.eql(u8, "add", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try Cli.addFeed(allocator, db_, value, stdout.writer(), stdin.reader());
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
            try db_.updateAllFeeds(allocator, .{ .force = force });
        } else if (mem.eql(u8, "clean", arg)) {
            try Cli.cleanItems(allocator);
        } else if (mem.eql(u8, "delete", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try Cli.deleteFeed(allocator, _db, value, stdout.writer(), stdin.reader());
            } else {
                l.err("Subcommand delete missing argument location", .{});
            }
        } else if (mem.eql(u8, "print", arg)) {
            // if (iter.next(allocator)) |value_err| {
            //     const value = try value_err;
            //     if (mem.eql(u8, "feeds", value)) {
            //         try printFeeds(&db_struct, allocator);
            //         return;
            //     }
            // }

            // try printAllItems(&db_struct, allocator);
        } else {
            l.err("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
}

const Cli = struct {
    pub fn addFeed(
        allocator: *Allocator,
        db_: *Db_,
        location_input: []const u8,
        writer: anytype,
        reader: anytype,
    ) !void {
        var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
        const abs_path_err = fs.cwd().realpath(location_input, &path_buf);
        if (abs_path_err) |abs_path| {
            errdefer l.warn("Failed to add local feed: {s}", .{abs_path});
            // Add local feed
            const contents = try getFileContents(allocator, abs_path);
            const feed = try parse.parse(allocator, contents);
            const id = try db_.addFeed(feed, abs_path);

            const mtime_sec = blk: {
                const file = try fs.openFileAbsolute(abs_path, .{});
                defer file.close();
                const stat = try file.stat();
                break :blk @intCast(i64, @divFloor(stat.mtime, time.ns_per_s));
            };

            try db_.addFeedLocal(id, mtime_sec);
            try db_.addItems(id, feed.items);
            try db_.cleanItemsByFeedId(id);
            try writer.print("Added local feed: {s}", .{abs_path});
        } else |err| switch (err) {
            error.FileNotFound => {
                errdefer l.warn("Failed to add url feed: {s}", .{location_input});
                const url = try http.makeUri(location_input);
                const resp = try resolveRequestToFeed(allocator, url, writer, reader);
                if (resp.body == null or resp.body.?.len == 0) {
                    l.warn("No body to parse", .{});
                    return error.NoBody;
                }

                // Parse feed data
                const feed = switch (resp.content_type) {
                    .xml_atom => try parse.Atom.parse(allocator, resp.body.?),
                    .xml_rss => try parse.Rss.parse(allocator, resp.body.?),
                    .xml => try parse.parse(allocator, resp.body.?),
                    .unknown => {
                        l.warn("Unknown content type was returned\n", .{});
                        return error.UnknownHttpContent;
                    },
                    .html => unreachable,
                };

                const location = try fmt.allocPrint(allocator, "{s}://{s}{s}", .{
                    resp.url.scheme,
                    resp.url.host.name,
                    resp.url.path,
                });
                defer allocator.free(location);

                // Add feed
                const feed_id = try db_.addFeed(feed, location);
                try db_.addFeedUrl(feed_id, resp);
                try db_.addItems(feed_id, feed.items);
                try db_.cleanItemsByFeedId(feed_id);

                try writer.print("Added url feed: {s}\n", .{location});
            },
            else => return err,
        }
    }

    fn resolveRequestToFeed(
        allocator: *Allocator,
        url: Uri,
        writer: anytype,
        reader: anytype,
    ) anyerror!http.FeedResponse {
        const req = http.FeedRequest{ .url = url };
        const resp = try http.resolveRequest(allocator, req);

        if (resp.content_type == .html) {
            const page_data = try parse.Html.parseLinks(allocator, resp.body.?);
            if (page_data.links.len == 0) {
                try writer.print("Found no RSS or Atom feed links\n", .{});
                return error.NoRssOrAtomLinksFound;
            }
            const link = try chooseFeedLink(allocator, page_data, resp.url, writer, reader);
            var rss_uri = try http.makeUri(link.href);
            if (rss_uri.host.name.len == 0) {
                rss_uri.scheme = resp.url.scheme;
                rss_uri.host.name = resp.url.host.name;
            }
            return try resolveRequestToFeed(allocator, rss_uri, writer, reader);
        }

        return resp;
    }

    fn chooseFeedLink(
        allocator: *Allocator,
        page_data: parse.Html.Page,
        url: Uri,
        writer: anytype,
        reader: anytype,
    ) !parse.Html.Link {
        var buf: [64]u8 = undefined;
        try writer.print("Choose feed to add\n", .{});
        const title = page_data.title orelse "<no-page-title>";
        try writer.print("{s}\n{s}\n", .{ title, url.host.name });
        for (page_data.links) |link, i| {
            const link_title = page_data.links[i].title orelse "<no-title>";
            if (link.href[0] != '/') {
                try writer.print("\t{d}. {s} -> {s}\n", .{ i + 1, link_title, link.href });
            } else {
                try writer.print("\t{d}. {s} -> {s}://{s}{s}\n", .{
                    i + 1,
                    link_title,
                    url.scheme,
                    url.host.name,
                    link.href,
                });
            }
        }

        const result_link = blk: {
            while (true) {
                try writer.print("Enter link number: ", .{});
                const bytes = try reader.read(&buf);
                const input = buf[0 .. bytes - 1];
                const nr = fmt.parseUnsigned(u16, input, 10) catch |err| {
                    try writer.print(
                        "Invalid number: '{s}'. Try again.\n",
                        .{input},
                    );
                    continue;
                };
                if (nr < 1 or nr > page_data.links.len) {
                    try writer.print(
                        "Number out of range: '{d}'. Try again.\n",
                        .{nr},
                    );
                    continue;
                }
                break :blk page_data.links[nr - 1];
            }
        };

        return result_link;
    }

    pub fn deleteFeed(
        allocator: *Allocator,
        db_: *Db_,
        search_input: []const u8,
        writer: anytype,
        reader: anytype,
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

        const search_term = try fmt.allocPrint(allocator, "%{s}%", .{search_input});
        defer allocator.free(search_term);

        const stdout = std.io.getStdOut();
        const results = try db.selectAll(DbResult, allocator, &db_.db, query, .{
            search_term,
            search_term,
            search_term,
        });
        if (results.len == 0) {
            try writer.print("Found no matches for '{s}' to delete.\n", .{search_input});
            return;
        }
        try writer.print("Found {} result(s):\n\n", .{results.len});
        for (results) |result, i| {
            const link = result.link orelse "<no-link>";
            try writer.print("{}. {s} | {s} | {s}\n", .{
                i + 1,
                result.title,
                link,
                result.location,
            });
        }
        var buf: [32]u8 = undefined;

        var delete_nr: usize = 0;
        while (true) {
            try writer.print("Enter feed number to delete? ", .{});
            const bytes = try reader.read(&buf);
            if (buf[0] == '\n') continue;

            if (fmt.parseUnsigned(usize, buf[0 .. bytes - 1], 10)) |nr| {
                if (nr >= 1 and nr <= results.len) {
                    delete_nr = nr;
                    break;
                }
                try writer.print("Entered number out of range. Try again.\n", .{});
                continue;
            } else |_| {
                try writer.print("Invalid number entered: '{s}'. Try again.\n", .{buf[0 .. bytes - 1]});
            }
        }

        const del_query =
            \\DELETE FROM feed WHERE id = ?;
        ;
        if (delete_nr > 0) {
            const result = results[delete_nr - 1];
            try db_.deleteFeed(result.id);
            try writer.print("Deleted feed '{s}'\n", .{result.location});
        }
    }

    pub fn cleanItems(allocator: *Allocator) !void {
        try db_.cleanItems(allocator);
    }
};

const TestIO = struct {
    const Self = @This();
    const warn_fmt =
        \\====== expected this output: =========
        \\{s}
        \\======== instead found this: =========
        \\{s}
        \\======================================
    ;

    const Action = union {
        write: []const u8,
        read: []const u8,
    };

    expected_actions: []Action,
    action_index: usize = 0,
    do_print: bool = false,

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    pub const Writer = std.io.Writer(*Self, Error, write);
    pub const Error = error{
        TooMuchData,
        DifferentData,
    };

    fn write(self: *Self, bytes: []const u8) Error!usize {
        const i = self.action_index;
        const expected = self.expected_actions[i].write;

        if (expected.len < bytes.len) {
            std.debug.warn(warn_fmt, .{ expected, bytes });
            return error.TooMuchData;
        }

        if (!mem.eql(u8, expected[0..bytes.len], bytes)) {
            std.debug.warn(warn_fmt, .{ expected[0..bytes.len], bytes });
            return error.DifferentData;
        }

        self.expected_actions[i].write = self.expected_actions[i].write[bytes.len..];
        if (expected.len == bytes.len) {
            self.action_index += 1;
        }

        if (self.do_print) print("{s}", .{bytes});
        return bytes.len;
    }

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    const Reader = std.io.Reader(*Self, Error, read);

    fn read(self: *Self, dest: []u8) Error!usize {
        const i = self.action_index;
        const src = self.expected_actions[i].read;
        const size = src.len;
        mem.copy(u8, dest[0..size], src);
        self.action_index += 1;
        if (self.do_print) print("{s}", .{src});
        return size;
    }
};

const TestCounts = struct {
    feed: usize = 0,
    local: usize = 0,
    url: usize = 0,
};

fn testCheckCounts(db_: *Db_, counts: TestCounts) !void {
    const feed_count_query = "select count(id) from feed";
    const local_count_query = "select count(feed_id) from feed_update_local";
    const url_count_query = "select count(feed_id) from feed_update_http";
    const item_count_query = "select count(DISTINCT feed_id) from item";

    const feed_count = try db.count(&db_.db, feed_count_query);
    const local_count = try db.count(&db_.db, local_count_query);
    const url_count = try db.count(&db_.db, url_count_query);
    const item_feed_count = try db.count(&db_.db, item_count_query);
    expect(feed_count == counts.feed);
    expect(local_count == counts.local);
    expect(feed_count == counts.local + counts.url);
    expect(url_count == counts.url);
    expect(item_feed_count == counts.feed);
}

test "Cli.addFeed(), Cli.deleteFeed()" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var db_ = try Db_.init(allocator, null);
    const do_print = false;
    var write_first = "Choose feed to add\n";
    var enter_link = "Enter link number: ";
    var read_valid = "1\n";
    const added_url = "Added url feed: ";
    var counts = TestCounts{};

    {
        // remove last slash to get HTTP redirect
        const location = "test/sample-rss-2.xml";
        const rss_url = "/media/hdd/code/feed_app/test/sample-rss-2.xml";
        var w = "Added local feed: " ++ rss_url ++ "\n";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = w },
            },
        };

        const writer = text_io.writer();
        const reader = text_io.reader();
        try Cli.addFeed(allocator, &db_, location, writer, reader);
        counts.feed += 1;
        counts.local += 1;
    }

    // {
    //     // remove last slash to get HTTP redirect
    //     const location = "old.reddit.com/r/programming/";
    //     const rss_url = "https://old.reddit.com/r/programming/.rss";
    //     var text_io = TestIO{
    //         .do_print = do_print,
    //         .expected_actions = &[_]TestIO.Action{
    //             .{ .write = write_first },
    //             .{ .write = "programming\nold.reddit.com\n" },
    //             .{ .write = "\t1. RSS -> " ++ rss_url ++ "\n" },
    //             .{ .write = enter_link },
    //             .{ .read = "abc\n" },
    //             .{ .write = "Invalid number: 'abc'. Try again.\n" },
    //             .{ .write = enter_link },
    //             .{ .read = "12\n" },
    //             .{ .write = "Number out of range: '12'. Try again.\n" },
    //             .{ .write = enter_link },
    //             .{ .read = read_valid },
    //             .{ .write = added_url ++ rss_url ++ "\n" },
    //         },
    //     };

    //     const writer = text_io.writer();
    //     const reader = text_io.reader();
    //     try Cli.addFeed(allocator, &db_, location, writer, reader);
    //     counts.feed += 1;
    //     counts.url += 1;
    // }

    // {
    //     // Feed url has to constructed because Html.Link.href is
    //     // absolute path - '/syndication/5701'
    //     const location = "https://www.royalroad.com/fiction/5701/savage-divinity";
    //     const rss_url = "https://www.royalroad.com/syndication/5701";
    //     var text_io = TestIO{
    //         .do_print = do_print,
    //         .expected_actions = &[_]TestIO.Action{
    //             .{ .write = write_first },
    //             .{ .write = "Savage Divinity | Royal Road\nwww.royalroad.com\n" },
    //             .{ .write = "\t1. Updates for Savage Divinity -> " ++ rss_url ++ "\n" },
    //             .{ .write = enter_link },
    //             .{ .read = read_valid },
    //             .{ .write = added_url ++ rss_url ++ "\n" },
    //         },
    //     };

    //     const writer = text_io.writer();
    //     const reader = text_io.reader();
    //     try Cli.addFeed(allocator, &db_, location, writer, reader);
    //     counts.feed += 1;
    //     counts.url += 1;
    // }

    try testCheckCounts(&db_, counts);

    {
        // Found no feed to delete
        const search_value = "doesnt_exist";
        var first = "Found no matches for '" ++ search_value ++ "' to delete.\n";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = first },
            },
        };

        const writer = text_io.writer();
        const reader = text_io.reader();
        try Cli.deleteFeed(allocator, &db_, search_value, writer, reader);
    }

    {
        // Delete a feed
        var enter_nr = "Enter feed number to delete? ";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = "Found 1 result(s):\n\n" },
                .{ .write = "1. Liftoff News | http://liftoff.msfc.nasa.gov/ | /media/hdd/code/feed_app/test/sample-rss-2.xml\n" },
                .{ .write = enter_nr },
                .{ .read = "1a\n" },
                .{ .write = "Invalid number entered: '1a'. Try again.\n" },
                .{ .write = enter_nr },
                .{ .read = "14\n" },
                .{ .write = "Entered number out of range. Try again.\n" },
                .{ .write = enter_nr },
                .{ .read = "1\n" },
                .{ .write = "Deleted feed '/media/hdd/code/feed_app/test/sample-rss-2.xml'\n" },
            },
        };

        const writer = text_io.writer();
        const reader = text_io.reader();
        try Cli.deleteFeed(allocator, &db_, "liftoff", writer, reader);
        counts.feed -= 1;
        counts.local -= 1;
    }

    try testCheckCounts(&db_, counts);
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

// Caller freed memory
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

test "local feed: add, update, remove" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var db_ = try Db_.init(allocator, null);

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
        const db_feeds = try db.selectAll(LocalResult, allocator, &db_.db, all_feeds_query, .{});
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
        const db_feeds = try db.selectAll(LocalUpdateResult, allocator, &db_.db, local_query, .{});
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
        const items = try db.selectAll(ItemsResult, allocator, &db_.db, all_items_query, .{});
        expect(items.len == feed.items.len);
    }

    try db_.updateAllFeeds(allocator, .{ .force = true });
    feed.items = all_items;

    // Items
    {
        const items = try db.selectAll(ItemsResult, allocator, &db_.db, all_items_query, .{});
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
        const local_updates = try db.selectAll(LocalUpdateResult, allocator, &db_.db, local_query, .{});
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
        var item_count = try db.count(&db_.db, item_count_query);
        expect(feed.items.len == item_count);

        // cleanItemsByFeedId()
        g.max_items_per_feed = 4;
        try db_.cleanItemsByFeedId(1);
        item_count = try db.count(&db_.db, item_count_query);
        expect(g.max_items_per_feed == item_count);

        // cleanItems()
        g.max_items_per_feed = 2;
        try db_.cleanItems(allocator);
        item_count = try db.count(&db_.db, item_count_query);
        expect(g.max_items_per_feed == item_count);
    }

    // Delete feed
    {
        try db_.deleteFeed(1);

        const feed_count = try db.count(&db_.db, "select count(id) from feed");
        expect(feed_count == 0);
        const local_update_count = try db.count(&db_.db, "select count(feed_id) from feed_update_local");
        expect(local_update_count == 0);
        const item_count = try db.count(&db_.db, item_count_query);
        expect(item_count == 0);
    }
}
