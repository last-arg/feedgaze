const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fs = std.fs;
const log = std.log;
const parse = @import("parse.zig");
const http = @import("http.zig");
const Uri = @import("zuri").Uri;
const time = std.time;
const fmt = std.fmt;
const mem = std.mem;
const print = std.debug.print;
const db = @import("db.zig");
const shame = @import("shame.zig");
const expect = std.testing.expect;
const assert = std.debug.assert;
const Storage = @import("feed_db.zig").Storage;

// TODO: reorganize Cli and its functions
// Use file root as struct or create separate struct (Cli)?
pub fn makeCli(
    allocator: Allocator,
    feed_db: *Storage,
    writer: anytype,
    reader: anytype,
) Cli(@TypeOf(writer), @TypeOf(reader)) {
    return Cli(@TypeOf(writer), @TypeOf(reader)){
        .allocator = allocator,
        .feed_db = feed_db,
        .writer = writer,
        .reader = reader,
    };
}

pub const CliOptions = struct {
    url: bool = true,
    local: bool = true,
    force: bool = false,
};

pub fn Cli(comptime Writer: type, comptime Reader: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        feed_db: *Storage,
        writer: Writer,
        reader: Reader,
        options: CliOptions = CliOptions{},

        const Host = struct {
            title: []const u8,
            name: []const u8,

            feeds: []const Feed,

            const Feed = struct {
                title: Fmt,
                link: Fmt,
            };

            const Fmt = struct {
                start: []const u8,
                end: []const u8,
            };
        };

        pub fn addFeed(
            self: *Self,
            location_input: []const u8,
        ) !void {
            var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
            if (self.options.local) {
                if (fs.cwd().realpath(location_input, &path_buf)) |abs_path| {
                    try self.addFeedLocal(abs_path);
                    return;
                } else |err| switch (err) {
                    error.FileNotFound => {}, // Skip to checking self.options.url
                    else => return err,
                }
            }
            if (self.options.url) {
                try self.addFeedHttp(location_input);
            }
        }

        pub fn addFeedLocal(self: *Self, abs_path: []const u8) !void {
            log.info("Add local feed: '{s}'", .{abs_path});
            errdefer log.warn("Failed to add local feed: {s}", .{abs_path});
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const contents = try shame.getFileContents(arena.allocator(), abs_path);
            const feed = try parse.parse(&arena, contents);

            const mtime_sec = blk: {
                const file = try fs.openFileAbsolute(abs_path, .{});
                defer file.close();
                const stat = try file.stat();
                break :blk @intCast(i64, @divFloor(stat.mtime, time.ns_per_s));
            };

            const id = try self.feed_db.addFeed(feed, abs_path);
            try self.feed_db.addFeedLocal(id, mtime_sec);
            try self.feed_db.addItems(id, feed.items);
            try self.writer.print("Added local feed: {s}", .{abs_path});
        }

        pub fn addFeedHttp(self: *Self, input_url: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const writer = self.writer;
            const feed_db = self.feed_db;

            const url = try makeValidUrl(arena.allocator(), input_url);
            try writer.print("Adding feed {s}\n", .{url});
            const resp = try getFeedHttp(&arena, url, writer, self.reader);
            switch (resp) {
                .fail => |msg| {
                    log.err("Failed to resolve url {s}", .{url});
                    log.err("Failed message: {s}", .{msg});
                    return;
                },
                .not_modified => {
                    log.err("Request returned not modified which should not be happening when adding new feed", .{});
                    return;
                },
                .ok => {},
            }
            const location = resp.ok.location;
            log.info("Feed fetched", .{});
            log.info("Feed location '{s}'", .{location});

            log.info("Parsing feed", .{});
            var feed = try parseFeedResponseBody(&arena, resp.ok.body, resp.ok.content_type);
            log.info("Feed parsed", .{});

            if (feed.link == null) feed.link = url;

            var savepoint = try feed_db.db.sql_db.savepoint("addFeedUrl");
            defer savepoint.rollback();
            const query = "select id, updated_timestamp from feed where location = ? limit 1;";
            if (try feed_db.db.one(Storage.UpdateFeedRow, query, .{location})) |row| {
                try writer.print("Feed already exists\nUpdating feed instead\n", .{});
                try feed_db.updateUrlFeed(row, resp.ok, feed, .{ .force = true });
                try writer.print("Feed updated {s}\n", .{location});
            } else {
                log.info("Saving feed", .{});
                const feed_id = try feed_db.addFeed(feed, location);
                try feed_db.addFeedUrl(feed_id, resp.ok);
                try feed_db.addItems(feed_id, feed.items);
                try writer.print("Feed added {s}\n", .{location});
            }
            savepoint.commit();
        }

        // TODO: Cli.deleteFeed
        pub fn deleteFeed(self: *Self, search_input: []const u8) !void {
            const results = try self.feed_db.search(self.allocator, search_input);

            if (results.len == 0) {
                try self.writer.print("Found no matches for '{s}' to delete.\n", .{search_input});
                return;
            }
            try self.writer.print("Found {} result(s):\n\n", .{results.len});
            for (results) |result, i| {
                const link = result.link orelse "<no-link>";
                try self.writer.print("{}. {s} | {s} | {s}\n", .{
                    i + 1,
                    result.title,
                    link,
                    result.location,
                });
            }
            var buf: [32]u8 = undefined;

            var delete_nr: usize = 0;
            while (true) {
                try self.writer.print("Enter feed number to delete? ", .{});
                const bytes = try self.reader.read(&buf);
                if (buf[0] == '\n') continue;

                if (fmt.parseUnsigned(usize, buf[0 .. bytes - 1], 10)) |nr| {
                    if (nr >= 1 and nr <= results.len) {
                        delete_nr = nr;
                        break;
                    }
                    try self.writer.print("Entered number out of range. Try again.\n", .{});
                    continue;
                } else |_| {
                    try self.writer.print("Invalid number entered: '{s}'. Try again.\n", .{buf[0 .. bytes - 1]});
                }
            }

            // const del_query =
            //     \\DELETE FROM feed WHERE id = ?;
            // ;
            if (delete_nr > 0) {
                const result = results[delete_nr - 1];
                try self.feed_db.deleteFeed(result.id);
                try self.writer.print("Deleted feed '{s}'\n", .{result.location});
            }
        }

        pub fn cleanItems(self: *Self) !void {
            try self.writer.print("Cleaning feeds' links.\n", .{});
            self.feed_db.cleanItems() catch {
                log.warn("Failed to clean feeds' links.", .{});
                return;
            };
            try self.writer.print("Feeds' items cleaned\n", .{});
        }

        pub fn printAllItems(self: *Self) !void {
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
                self.allocator,
                &self.feed_db.db,
                most_recent_feeds_query,
                .{},
            );

            if (most_recent_feeds.len == 0) {
                try self.writer.print("There are 0 feeds\n", .{});
                return;
            }

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
                \\	pub_date_utc DESC,
                \\  created_at DESC
            ;

            const all_items = try db.selectAll(
                Result,
                self.allocator,
                &self.feed_db.db,
                all_items_query,
                .{},
            );

            for (most_recent_feeds) |feed| {
                const id = feed.id;
                const start_index = blk: {
                    for (all_items) |item, idx| {
                        if (item.id == id) break :blk idx;
                    }
                    break; // Should not happen
                };
                const feed_link = feed.link orelse "<no-link>";
                try self.writer.print("{s} - {s}\n", .{ feed.title, feed_link });
                for (all_items[start_index..]) |item| {
                    if (item.id != id) break;
                    const item_link = item.link orelse "<no-link>";
                    try self.writer.print("  {s}\n  {s}\n\n", .{
                        item.title,
                        item_link,
                    });
                }
            }
        }

        pub fn updateFeeds(self: *Self) !void {
            if (self.options.url) {
                self.feed_db.updateUrlFeeds(.{ .force = self.options.force }) catch {
                    log.err("Failed to update feeds", .{});
                    return;
                };
                try self.writer.print("Updated url feeds\n", .{});
            }
            if (self.options.local) {
                self.feed_db.updateLocalFeeds(.{ .force = self.options.force }) catch {
                    log.err("Failed to update local feeds", .{});
                    return;
                };
                try self.writer.print("Updated local feeds\n", .{});
            }
        }

        pub fn printFeeds(self: *Self) !void {
            const Result = struct {
                title: []const u8,
                location: []const u8,
                link: ?[]const u8,
            };
            const query =
                \\SELECT title, location, link FROM feed
            ;
            var stmt = try self.feed_db.db.prepare(query);
            defer stmt.deinit();
            const all_items = stmt.all(Result, self.allocator, .{}, .{}) catch |err| {
                log.warn("{s}\nFailed query:\n{s}", .{ self.feed_db.db.getDetailedError().message, query });
                return err;
            };
            try self.writer.print("There are {} feed(s)\n", .{all_items.len});

            const print_fmt =
                \\{s}
                \\  link: {s}
                \\  location: {s}
                \\
                \\
            ;

            for (all_items) |item| {
                const link = item.link orelse "<no-link>";
                try self.writer.print(print_fmt, .{ item.title, link, item.location });
            }
        }

        // TODO: Cli.search
        pub fn search(self: *Self, term: []const u8) !void {
            const results = try self.feed_db.search(self.allocator, term);
            if (results.len == 0) {
                try self.writer.print("Found no matches\n", .{});
                return;
            }

            try self.writer.print("Found {} match(es):\n", .{results.len});
            // TODO?: display data as table
            for (results) |result| {
                try self.writer.print("{s}\n\tid: {}\n\tlink: {s}\n\tfeed link: {s}\n", .{ result.title, result.id, result.link, result.location });
            }
        }
    };
}

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
        NoExpectedWrites,
        IndexOutOfBounds,
    };

    fn write(self: *Self, bytes: []const u8) Error!usize {
        if (self.expected_actions.len == 0) return error.NoExpectedWrites;
        const i = self.action_index;
        if (i >= self.expected_actions.len) {
            log.err("Index out of bound. Didn't print: {s}", .{bytes});
            return bytes.len;
        }
        const expected = self.expected_actions[i].write;

        if (expected.len < bytes.len) {
            print(warn_fmt, .{ expected, bytes });
            return error.TooMuchData;
        }

        if (!mem.eql(u8, expected[0..bytes.len], bytes)) {
            print(warn_fmt, .{ expected[0..bytes.len], bytes });
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

fn expectCounts(feed_db: *Storage, counts: TestCounts) !void {
    const feed_count_query = "select count(id) from feed";
    const local_count_query = "select count(feed_id) from feed_update_local";
    const url_count_query = "select count(feed_id) from feed_update_http";
    const item_count_query = "select count(DISTINCT feed_id) from item";

    const feed_count = try feed_db.db.one(usize, feed_count_query, .{});
    const local_count = try feed_db.db.one(usize, local_count_query, .{});
    const url_count = try feed_db.db.one(usize, url_count_query, .{});
    const item_feed_count = try feed_db.db.one(usize, item_count_query, .{});
    try expect(feed_count == counts.feed);
    try expect(local_count == counts.local);
    try expect(feed_count == counts.local + counts.url);
    try expect(url_count == counts.url);
    try expect(item_feed_count == counts.feed);
}

test "Cli.printAllItems, Cli.printFeeds" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var feed_db = try Storage.init(allocator, null);

    var cli = Cli(TestIO.Writer, TestIO.Reader){
        .allocator = allocator,
        .feed_db = &feed_db,
        .writer = undefined,
        .reader = undefined,
    };

    {
        const location = "test/sample-rss-2.xml";
        const rss_url = "/media/hdd/code/feedgaze/test/sample-rss-2.xml";
        var w = "Added local feed: " ++ rss_url ++ "\n";
        var text_io = TestIO{ .expected_actions = &[_]TestIO.Action{.{ .write = w }} };

        cli.writer = text_io.writer();
        try cli.addFeed(location);
    }

    {
        var first = "Liftoff News - http://liftoff.msfc.nasa.gov/\n";
        var text_io = TestIO{
            .expected_actions = &[_]TestIO.Action{
                .{ .write = first },
                .{ .write = "  Star City\n  http://liftoff.msfc.nasa.gov/news/2003/news-starcity.asp\n\n" },
                .{ .write = "  Sky watchers in Europe, Asia, \n  <no-link>\n\n" },
                .{ .write = "  TEST THIS\n  <no-link>\n\n" },
                .{ .write = "  Astronauts' Dirty Laundry\n  http://liftoff.msfc.nasa.gov/news/2003/news-laundry.asp\n\n" },
                .{ .write = "  The Engine That Does More\n  http://liftoff.msfc.nasa.gov/news/2003/news-VASIMR.asp\n\n" },
                .{ .write = "  TEST THIS1\n  <no-link>\n\n" },
            },
        };
        cli.writer = text_io.writer();
        try cli.printAllItems();
    }

    {
        var first = "There are 1 feed(s)\n";
        var text_io = TestIO{
            .expected_actions = &[_]TestIO.Action{
                .{ .write = first },
                .{ .write = "Liftoff News\n  link: http://liftoff.msfc.nasa.gov/\n  location: /media/hdd/code/feedgaze/test/sample-rss-2.xml\n\n" },
            },
        };
        cli.writer = text_io.writer();
        try cli.printFeeds();
    }
}

test "Cli.cleanItems" {
    std.testing.log_level = .debug;

    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var storage = try Storage.init(allocator, null);
    const parse_feed = parse.Feed{ .title = "Feed title", .id = null };
    const id1 = try storage.addFeed(parse_feed, "feed_location");
    const id2 = try storage.addFeed(parse_feed, "another_location");

    const feed_db = @import("feed_db.zig");
    feed_db.g.max_items_per_feed = 2;
    var first_title1 = "items1: first title";
    const items1: []parse.Feed.Item = &[_]parse.Feed.Item{
        .{ .title = first_title1 },
        .{ .title = "items1: second title" },
        .{ .title = "items1: third title" },
    };

    var first_title2 = "items2: first title";
    const items2 = &[_]parse.Feed.Item{.{ .title = first_title2 }};

    try storage.addItems(id1, items1);
    try storage.addItems(id2, items2);

    var cli = Cli(TestIO.Writer, TestIO.Reader){
        .allocator = allocator,
        .feed_db = &storage,
        .writer = undefined,
        .reader = undefined,
    };

    var first = "Cleaning feeds' links.\n";
    var text_io = TestIO{
        .expected_actions = &[_]TestIO.Action{ .{ .write = first }, .{ .write = "Feeds' items cleaned\n" } },
    };

    cli.writer = text_io.writer();
    try cli.cleanItems();
    const count_query = "select count(feed_id) from item WHERE feed_id = ?";

    const count1 = try storage.db.one(usize, count_query, .{id1});
    try expect(count1.? == feed_db.g.max_items_per_feed);
    const count2 = try storage.db.one(usize, count_query, .{id2});
    try expect(count2.? == items2.len);
}

test "local feed: add, update, delete" {
    const g = @import("feed_db.zig").g;
    std.testing.log_level = .debug;

    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var feed_db = try Storage.init(allocator, null);
    const do_print = false;
    var counts = TestCounts{};

    var cli = Cli(TestIO.Writer, TestIO.Reader){
        .allocator = allocator,
        .feed_db = &feed_db,
        .writer = undefined,
        .reader = undefined,
    };

    {
        const location = "test/sample-rss-2.xml";
        const rss_url = "/media/hdd/code/feedgaze/test/sample-rss-2.xml";
        var w = "Added local feed: " ++ rss_url ++ "\n";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = w },
            },
        };

        cli.writer = text_io.writer();
        try cli.addFeed(location);
        counts.feed += 1;
        counts.local += 1;
    }

    try expectCounts(&feed_db, counts);

    {
        const query = "select count(feed_id) from item group by feed_id";
        const results = try feed_db.db.selectAll(usize, query, .{});
        for (results) |item_count| {
            try expect(item_count <= g.max_items_per_feed);
        }
    }

    {
        var first = "Updated url feeds\n";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = first },
                .{ .write = "Updated local feeds\n" },
            },
        };
        cli.writer = text_io.writer();
        try cli.updateFeeds();
    }

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

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.deleteFeed(search_value);
    }

    {
        // Delete a feed
        var enter_nr = "Enter feed number to delete? ";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = "Found 1 result(s):\n\n" },
                .{ .write = "1. Liftoff News | http://liftoff.msfc.nasa.gov/ | /media/hdd/code/feedgaze/test/sample-rss-2.xml\n" },
                .{ .write = enter_nr },
                .{ .read = "1a\n" },
                .{ .write = "Invalid number entered: '1a'. Try again.\n" },
                .{ .write = enter_nr },
                .{ .read = "14\n" },
                .{ .write = "Entered number out of range. Try again.\n" },
                .{ .write = enter_nr },
                .{ .read = "1\n" },
                .{ .write = "Deleted feed '/media/hdd/code/feedgaze/test/sample-rss-2.xml'\n" },
            },
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.deleteFeed("liftoff");
        counts.feed -= 1;
        counts.local -= 1;
    }

    try expectCounts(&feed_db, counts);
}

// TODO: remove or redo
test "url: Cli.addFeed(), Cli.deleteFeed(), Cli.updateFeeds()" {
    std.testing.log_level = .debug;
    const g = @import("feed_db.zig").g;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var feed_db = try Storage.init(allocator, null);
    const do_print = true;
    var write_first = "Choose feed to add\n";
    var enter_link = "Enter link number: ";
    var read_valid = "1\n";
    var added_url = "Added url feed: ";
    var counts = TestCounts{};

    var cli = Cli(TestIO.Writer, TestIO.Reader){
        .allocator = allocator,
        .feed_db = &feed_db,
        .writer = undefined,
        .reader = undefined,
    };

    {
        // Test reddit.com
        const url_end = ".rss?sort=new";
        const location = "https://www.reddit.com/r/programming/.rss";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = added_url },
                .{ .write = "https://old.reddit.com/r/programming/" ++ url_end ++ "\n" },
            },
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.addFeed(location);
        counts.feed += 1;
        counts.url += 1;
    }

    if (true) return;

    {
        // remove last slash to get HTTP redirect
        const location = "old.reddit.com/r/programming/";
        const rss_url = "https://old.reddit.com/r/programming/.rss";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = write_first },
                .{ .write = "programming\nold.reddit.com\n" },
                .{ .write = "\t1. RSS -> " ++ rss_url ++ "\n" },
                .{ .write = enter_link },
                .{ .read = "abc\n" },
                .{ .write = "Invalid number: 'abc'. Try again.\n" },
                .{ .write = enter_link },
                .{ .read = "12\n" },
                .{ .write = "Number out of range: '12'. Try again.\n" },
                .{ .write = enter_link },
                .{ .read = read_valid },
                .{ .write = added_url ++ rss_url ++ "\n" },
            },
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.addFeed(location);
        counts.feed += 1;
        counts.url += 1;
    }

    {
        // Feed url has to constructed because Html.Link.href is
        // absolute path - '/syndication/5701'
        const location = "https://www.royalroad.com/fiction/5701/savage-divinity";
        const rss_url = "https://www.royalroad.com/syndication/5701";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = write_first },
                .{ .write = "Savage Divinity | Royal Road\nwww.royalroad.com\n" },
                .{ .write = "\t1. Updates for Savage Divinity -> " ++ rss_url ++ "\n" },
                .{ .write = enter_link },
                .{ .read = read_valid },
                .{ .write = added_url ++ rss_url ++ "\n" },
            },
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.addFeed(location);
        counts.feed += 1;
        counts.url += 1;
    }

    try expectCounts(&feed_db, counts);

    {
        const query = "select count(feed_id) from item group by feed_id";
        const results = try db.selectAll(usize, allocator, &feed_db.db, query, .{});
        for (results) |item_count| {
            try expect(item_count <= g.max_items_per_feed);
        }
    }

    {
        var first = "Updated url feeds\n";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = first },
                .{ .write = "Updated local feeds\n" },
            },
        };
        cli.writer = text_io.writer();
        try cli.updateFeeds(.{ .force = false });
    }

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

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.deleteFeed(search_value);
    }

    {
        // Delete a feed
        var enter_nr = "Enter feed number to delete? ";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = "Found 1 result(s):\n\n" },
                .{ .write = "1. programming | https://old.reddit.com/r/programming/.rss | https://old.reddit.com/r/programming/.rss\n" },
                .{ .write = enter_nr },
                .{ .read = "1a\n" },
                .{ .write = "Invalid number entered: '1a'. Try again.\n" },
                .{ .write = enter_nr },
                .{ .read = "14\n" },
                .{ .write = "Entered number out of range. Try again.\n" },
                .{ .write = enter_nr },
                .{ .read = "1\n" },
                .{ .write = "Deleted feed 'https://old.reddit.com/r/programming/.rss'\n" },
            },
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.deleteFeed("programming");
        counts.feed -= 1;
        counts.url -= 1;
    }

    try expectCounts(&feed_db, counts);
}

fn makeValidUrl(allocator: Allocator, url: []const u8) ![]const u8 {
    const no_http = !std.ascii.startsWithIgnoreCase(url, "http");
    const substr = "://";
    const start = if (std.ascii.indexOfIgnoreCase(url, substr)) |idx| idx + substr.len else 0;
    const no_slash = std.mem.indexOfScalar(u8, url[start..], '/') == null;
    if (no_http and no_slash) {
        return try fmt.allocPrint(allocator, "http://{s}/", .{url});
    } else if (no_http) {
        return try fmt.allocPrint(allocator, "http://{s}", .{url});
    } else if (no_slash) {
        return try fmt.allocPrint(allocator, "{s}/", .{url});
    }
    return try fmt.allocPrint(allocator, "{s}", .{url});
}

test "makeValidUrl()" {
    const allocator = std.testing.allocator;
    const urls = .{ "google.com", "google.com/", "http://google.com", "http://google.com/" };
    inline for (urls) |url| {
        const new_url = try makeValidUrl(allocator, url);
        defer if (!std.mem.eql(u8, url, new_url)) allocator.free(new_url);
        try std.testing.expectEqualStrings("http://google.com/", new_url);
    }
}

fn pickFeedLink(
    page: parse.Html.Page,
    url: []const u8,
    writer: anytype,
    reader: anytype,
) ![]const u8 {
    const no_title = "<no-title>";
    const page_title = page.title orelse no_title;
    try writer.print("{s}\n{s}\n", .{ page_title, url });

    for (page.links) |link, i| {
        const link_title = link.title orelse no_title;
        try writer.print("  {d}. [{s}] {s} | {s}\n", .{
            i + 1,
            parse.Html.MediaType.toString(link.media_type),
            link.href,
            link_title,
        });
    }

    // TODO?: can input several numbers. Comma or space separated, or both?
    var buf: [64]u8 = undefined;
    const index = blk: {
        while (true) {
            try writer.print("Enter link number: ", .{});
            const bytes = try reader.read(&buf);
            const input = buf[0 .. bytes - 1];
            const nr = fmt.parseUnsigned(u16, input, 10) catch {
                try writer.print(
                    "Invalid number: '{s}'. Try again.\n",
                    .{input},
                );
                continue;
            };
            if (nr < 1 or nr > page.links.len) {
                try writer.print(
                    "Number out of range: '{d}'. Try again.\n",
                    .{nr},
                );
                continue;
            }
            break :blk nr - 1;
        }
    };

    return page.links[index].href;
}

fn getFeedHttp(arena: *ArenaAllocator, url: []const u8, writer: anytype, reader: anytype) !http.FeedResponse {
    // make http request
    var resp = try http.resolveRequest(arena, url, null, null);
    const html_data = if (resp == .ok and resp.ok.content_type == .html)
        try parse.Html.parseLinks(arena.allocator(), resp.ok.body)
    else
        null;

    if (html_data) |data| {
        if (data.links.len > 0) {
            // user input
            const new_url = try pickFeedLink(data, resp.ok.location, writer, reader);
            // make new http request
            resp = try http.resolveRequest(arena, new_url, null, null);
        } else {
            try writer.print("Found no feed links in html\n", .{});
        }
    }

    return resp;
}

test "getFeedHttp()" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    var enter_link = "Enter link number: ";
    var read_valid = "1\n";
    var text_io = TestIO{
        .do_print = true,
        .expected_actions = &[_]TestIO.Action{
            .{ .write = "Commits · truemedian/zfetch · GitHub\nhttps://github.com/truemedian/zfetch/commits\n" },
            .{ .write = "  1. [Atom] https://github.com/truemedian/zfetch/commits/master.atom | Recent Commits to zfetch:master\n" },
            .{ .write = enter_link },
            .{ .read = "abc\n" },
            .{ .write = "Invalid number: 'abc'. Try again.\n" },
            .{ .write = enter_link },
            .{ .read = "12\n" },
            .{ .write = "Number out of range: '12'. Try again.\n" },
            .{ .write = enter_link },
            .{ .read = read_valid },
        },
    };
    const writer = text_io.writer();
    const reader = text_io.reader();

    const r = try getFeedHttp(&arena, "https://github.com/truemedian/zfetch/commits", writer, reader); // return html
    if (r == .fail) print("Getting feed failed: {s}\n", .{r.fail});
    // print("{}\n", .{r});
}

pub fn parseFeedResponseBody(
    arena: *ArenaAllocator,
    body: []const u8,
    content_type: http.ContentType,
) !parse.Feed {
    return switch (content_type) {
        .xml => try parse.parse(arena, body),
        .xml_atom => try parse.Atom.parse(arena, body),
        .xml_rss => try parse.Rss.parse(arena, body),
        .json => unreachable,
        .json_feed => @panic("TODO: parse json feed"),
        .html, .unknown => unreachable, // .html should be parse before calling this function
    };
}

test "add new feed" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    const url = "https://lobste.rs/";
    var actions = [_]TestIO.Action{
        .{ .write = "Adding feed " ++ url ++ "\n" },
        .{ .write = "Feed added " ++ url ++ "\n" },
    };
    var text_io = TestIO{
        .do_print = true,
        .expected_actions = &actions,
    };
    const writer = text_io.writer();
    const reader = text_io.reader();
    var feed_db = try Storage.init(arena.allocator(), null);
    var cli = makeCli(arena.allocator(), &feed_db, writer, reader);
    try cli.addFeed(url);
}

test "add new feed: feed exists, update instead" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;

    const url = "https://lobste.rs/";
    var actions = [_]TestIO.Action{
        .{ .write = "Adding feed " ++ url ++ "\n" },
        .{ .write = "Feed already exists\nUpdating feed instead\n" },
        .{ .write = "Feed updated " ++ url ++ "\n" },
    };
    var text_io = TestIO{
        .do_print = true,
        .expected_actions = &actions,
    };
    const writer = text_io.writer();
    const reader = text_io.reader();
    var feed_db = try Storage.init(base_allocator, null);
    const feed = parse.Feed{ .title = "Lobster title" };
    _ = try feed_db.addFeed(feed, url);
    var cli = makeCli(base_allocator, &feed_db, writer, reader);
    try cli.addFeed(url);
}
