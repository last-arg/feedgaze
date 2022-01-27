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
const expectEqual = std.testing.expectEqual;
const assert = std.debug.assert;
const Storage = @import("feed_db.zig").Storage;

pub fn makeCli(
    allocator: Allocator,
    feed_db: *Storage,
    options: CliOptions,
    writer: anytype,
    reader: anytype,
) Cli(@TypeOf(writer), @TypeOf(reader)) {
    return Cli(@TypeOf(writer), @TypeOf(reader)){
        .allocator = allocator,
        .feed_db = feed_db,
        .options = options,
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
            locations: []const []const u8,
        ) !void {
            var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
            for (locations) |location| {
                if (self.options.local) {
                    if (fs.cwd().realpath(location, &path_buf)) |abs_path| {
                        try self.addFeedLocal(abs_path);
                        try self.writer.print("Added local feed: {s}\n", .{abs_path});
                        continue;
                    } else |err| switch (err) {
                        error.FileNotFound => {}, // Skip to checking self.options.url
                        else => {
                            log.err("Failed to add local feed '{s}'.", .{location});
                            log.err("Error: '{s}'.", .{err});
                            continue;
                        },
                    }
                }
                if (self.options.url) {
                    self.addFeedHttp(location) catch |err| {
                        log.err("Failed to add url feed '{s}'.", .{location});
                        log.err("Error: '{s}'.", .{err});
                    };
                }
            }
        }

        pub fn addFeedLocal(self: *Self, abs_path: []const u8) !void {
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
        }

        pub fn addFeedHttp(self: *Self, input_url: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const writer = self.writer;
            const feed_db = self.feed_db;

            const url = try makeValidUrl(arena.allocator(), input_url);
            // TODO: change to 'Try to fetch feed'
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
            const query = "select id as feed_id, updated_timestamp from feed where location = ? limit 1;";
            if (try feed_db.db.one(Storage.CurrentData, query, .{location})) |row| {
                try writer.print("Feed exists. Updating feed {s}\n", .{location});
                try feed_db.updateUrlFeed(.{
                    .current = row,
                    .headers = resp.ok.headers,
                    .feed = feed,
                }, .{ .force = true });
                try writer.print("Feed updated {s}\n", .{location});
            } else {
                log.info("Saving feed", .{});
                const feed_id = try feed_db.addFeed(feed, location);
                try feed_db.addFeedUrl(feed_id, resp.ok.headers);
                try feed_db.addItems(feed_id, feed.items);
                try writer.print("Feed added {s}\n", .{location});
            }
            savepoint.commit();
        }

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
                id: u64,
            };

            // most recently updated feed
            const most_recent_feeds_query = "SELECT title, link, id FROM feed;";
            const most_recent_feeds = try self.feed_db.db.selectAll(Result, most_recent_feeds_query, .{});

            if (most_recent_feeds.len == 0) {
                try self.writer.print("There are 0 feeds\n", .{});
                return;
            }

            // grouped by feed_id
            const all_items_query =
                \\SELECT
                \\	title, link, feed_id
                \\FROM
                \\	item
                \\ORDER BY
                \\	feed_id DESC,
                \\	pub_date_utc DESC,
                \\  modified_at DESC
            ;

            const all_items = try self.feed_db.db.selectAll(Result, all_items_query, .{});

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
            const query = "SELECT title, location, link FROM feed;";
            var stmt = try self.feed_db.db.sql_db.prepare(query);
            defer stmt.deinit();
            const all_items = stmt.all(Result, self.allocator, .{}, .{}) catch |err| {
                log.warn("{s}\nFailed query:\n{s}", .{ self.feed_db.db.sql_db.getDetailedError().message, query });
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
    // TODO: look at std.testing.expectFmt()
    const warn_fmt =
        \\
        \\====== expected this output: =========
        \\{s}
        \\======== instead found this: =========
        \\{s}
        \\======================================
        \\
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
            log.err("TestIO: Index out of bound.\nDidn't print: {s}", .{bytes});
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
                .{ .write = "  Star City&#39;s Test\n  http://liftoff.msfc.nasa.gov/news/2003/news-starcity.asp\n\n" },
                .{ .write = "  Sky watchers in Europe, Asia, and parts of Alaska \n  <no-link>\n\n" },
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

fn makeWholeUrl(allocator: Allocator, uri: Uri, link: []const u8) ![]const u8 {
    if (link[0] == '/') {
        if (uri.port) |port| {
            if (port != 443 and port != 80) {
                return try fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ uri.scheme, uri.host.name, uri.port, link });
            }
        }
        return try fmt.allocPrint(allocator, "{s}://{s}{s}", .{ uri.scheme, uri.host.name, link });
    }
    return try fmt.allocPrint(allocator, "{s}", .{link});
}

fn printUrl(uri: Uri, writer: anytype) !void {
    try writer.print("{s}://{s}", .{ uri.scheme, uri.host.name });
    if (uri.port) |port| {
        if (port != 443 and port != 80) {
            try writer.print(":{d}", .{port});
        }
    }
    try writer.print("{s}", .{uri.path});
}

// TODO: use it in deleteFeed fn also if possible
fn pickFeedLink(
    allocator: Allocator,
    page: parse.Html.Page,
    uri: Uri,
    writer: anytype,
    reader: anytype,
) !u32 {
    const no_title = "<no-title>";
    const page_title = page.title orelse no_title;
    try writer.print("{s} | ", .{page_title});
    try printUrl(uri, writer);
    try writer.print("\n", .{});

    var stack_fallback = std.heap.stackFallback(128, allocator);
    const stack_allocator = stack_fallback.get();
    for (page.links) |link, i| {
        const whole_link = try makeWholeUrl(stack_allocator, uri, link.href);
        defer stack_allocator.free(whole_link);
        const link_title = link.title orelse no_title;
        try writer.print("  {d}. [{s}] {s} | {s}\n", .{
            i + 1,
            parse.Html.MediaType.toString(link.media_type),
            whole_link,
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

    return index;
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
            const uri = try Uri.parse(resp.ok.location, true);
            // user input
            const index = try pickFeedLink(arena.allocator(), data, uri, writer, reader);
            const new_url = try makeWholeUrl(arena.allocator(), uri, data.links[index].href);
            resp = try http.resolveRequest(arena, new_url, null, null);
        } else {
            try writer.print("Found no feed links in html\n", .{});
        }
    }

    return resp;
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

test "@active local and url: add, update, delete, html links, add into update" {
    const g = @import("feed_db.zig").g;
    std.testing.log_level = .debug;

    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var storage = try Storage.init(allocator, null);
    const do_print = true;
    var cli = Cli(TestIO.Writer, TestIO.Reader){
        .allocator = allocator,
        .feed_db = &storage,
        .writer = undefined,
        .reader = undefined,
    };

    // local 'test/rss2.xml' and url 'http://localhost:8080/rss2.rss' have same content

    // add local feed
    const rel_path = "test/rss2.xml";
    const abs_path = "/media/hdd/code/feedgaze/" ++ rel_path;
    {
        g.max_items_per_feed = 1;
        var w = "Added local feed: " ++ abs_path ++ "\n";
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &[_]TestIO.Action{
                .{ .write = w },
            },
        };

        cli.writer = text_io.writer();
        try cli.addFeed(&.{rel_path});
    }

    const added_url = "Adding feed ";
    // add url feed
    const url = "http://localhost:8080/rss2.rss";
    {
        g.max_items_per_feed = 2;
        var actions = [_]TestIO.Action{
            .{ .write = added_url },
            .{ .write = url ++ "\n" },
            .{ .write = "Feed added " ++ url ++ "\n" },
            .{ .write = "Added url feed: " ++ url ++ "\n" },
        };
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &actions,
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.addFeed(&.{url});
    }

    const FeedResult = struct {
        id: u64,
        title: []const u8,
        link: ?[]const u8,
        updated_raw: ?[]const u8,
        updated_timestamp: ?i64,
    };

    const ItemResult = struct {
        title: []const u8,
        link: ?[]const u8,
        guid: ?[]const u8,
        pub_date: ?[]const u8,
        pub_date_utc: ?i64,
    };

    var local_id: u64 = undefined;
    var url_id: u64 = undefined;

    // test if local and url feeds' table fields have same values
    {
        const feed_query = "select id,title,link,updated_raw,updated_timestamp from feed";
        const feeds = try storage.db.selectAll(FeedResult, feed_query, .{});
        try expectEqual(@as(usize, 2), feeds.len);
        const local_result = feeds[0];
        const url_result = feeds[1];
        local_id = local_result.id;
        url_id = url_result.id;
        try std.testing.expectEqualStrings(local_result.title, url_result.title);
        if (local_result.link) |link| try std.testing.expectEqualStrings(link, url_result.link.?);
        if (local_result.updated_raw) |updated_raw| try std.testing.expectEqualStrings(updated_raw, url_result.updated_raw.?);
        if (local_result.updated_timestamp) |updated_timestamp| try std.testing.expectEqual(updated_timestamp, url_result.updated_timestamp.?);
    }

    // test row count in feed_update_local and feed_update_http tables
    {
        const feed_url_local_counts_query = "select count(feed_update_local.feed_id) as local_count, count(feed_update_http.feed_id) as url_count from feed_update_local, feed_update_http";
        const counts = try storage.db.one(struct { local_count: u32, url_count: u32 }, feed_url_local_counts_query, .{});
        try expectEqual(@as(usize, 1), counts.?.local_count);
        try expectEqual(@as(usize, 1), counts.?.url_count);
    }

    // test if two feeds' first(newest) items are same
    const item_query = "select title,link,guid,pub_date,pub_date_utc from item where feed_id = ? order by id DESC";
    {
        const local_items = try storage.db.selectAll(ItemResult, item_query, .{local_id});
        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, 1), local_items.len);
        try expectEqual(@as(usize, 2), url_items.len);
        const l_item = local_items[0];
        const u_item = url_items[0];
        try std.testing.expectEqualStrings(l_item.title, u_item.title);
        if (l_item.link) |link| try std.testing.expectEqualStrings(link, u_item.link.?);
        if (l_item.guid) |guid| try std.testing.expectEqualStrings(guid, u_item.guid.?);
        if (l_item.pub_date) |pub_date| try std.testing.expectEqualStrings(pub_date, u_item.pub_date.?);
        if (l_item.pub_date_utc) |pub_date_utc| try std.testing.expectEqual(pub_date_utc, u_item.pub_date_utc.?);
    }

    g.max_items_per_feed = 10;
    {
        const html_url = "http://localhost:8080/many-links.html";
        const links_write =
            \\  1. [RSS] http://localhost:8080/rss2.rss | Rss 2
            \\  2. [Unknown] http://localhost:8080/rss2.xml | Rss 2
            \\  3. [Atom] http://localhost:8080/atom.atom | Atom feed
            \\  4. [Atom] http://localhost:8080/rss2.rss | Not Duplicate
            \\  5. [Unknown] http://localhost:8080/atom.xml | Atom feed
            \\
        ;
        const html_feed_url = "http://localhost:8080/rss2.rss";
        var actions = [_]TestIO.Action{
            .{ .write = added_url },
            .{ .write = html_url ++ "\n" },
            .{ .write = "Parse Feed Links | " ++ html_url ++ "\n" },
            .{ .write = links_write },
            .{ .write = "Enter link number: " },
            .{ .read = "1\n" },
            .{ .write = "Feed exists. Updating feed " ++ html_feed_url ++ "\n" },
            .{ .write = "Feed updated " ++ html_feed_url ++ "\n" },
        };

        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &actions,
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.addFeed(&.{html_url});

        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, 6), url_items.len);
    }

    // Test updating feeds
    {
        var actions = [_]TestIO.Action{
            .{ .write = "Updated url feeds\n" },
            .{ .write = "Updated local feeds\n" },
        };
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &actions,
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        cli.options.force = true;
        try cli.updateFeeds();
        cli.options.force = false;

        const local_items = try storage.db.selectAll(ItemResult, item_query, .{local_id});
        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, 6), local_items.len);
        try expectEqual(local_items.len, url_items.len);
        for (local_items) |l_item, i| {
            const u_item = url_items[i];
            try std.testing.expectEqualStrings(l_item.title, u_item.title);
            if (l_item.link) |link| try std.testing.expectEqualStrings(link, u_item.link.?);
            if (l_item.guid) |guid| try std.testing.expectEqualStrings(guid, u_item.guid.?);
            if (l_item.pub_date) |pub_date| try std.testing.expectEqualStrings(pub_date, u_item.pub_date.?);
            if (l_item.pub_date_utc) |pub_date_utc| try std.testing.expectEqual(pub_date_utc, u_item.pub_date_utc.?);
        }
    }

    // Test cleaning items
    {
        g.max_items_per_feed = 2;
        try storage.cleanItems();
        const local_items = try storage.db.selectAll(ItemResult, item_query, .{local_id});
        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, g.max_items_per_feed), local_items.len);
        try expectEqual(@as(usize, g.max_items_per_feed), url_items.len);
    }

    // delete local feed.
    var enter_nr = "Enter feed number to delete? ";
    {
        var actions = [_]TestIO.Action{
            .{ .write = "Found 2 result(s):\n\n" },
            .{ .write = "1. Liftoff News | http://liftoff.msfc.nasa.gov/ | " ++ abs_path ++ "\n" },
            .{ .write = "2. Liftoff News | http://liftoff.msfc.nasa.gov/ | " ++ url ++ "\n" },
            .{ .write = enter_nr },
            .{ .read = "1a\n" },
            .{ .write = "Invalid number entered: '1a'. Try again.\n" },
            .{ .write = enter_nr },
            .{ .read = "14\n" },
            .{ .write = "Entered number out of range. Try again.\n" },
            .{ .write = enter_nr },
            .{ .read = "1\n" },
            .{ .write = "Deleted feed '" ++ abs_path ++ "'\n" },
        };
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &actions,
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.deleteFeed("rss2");
    }

    // delete url feed.
    {
        var actions = [_]TestIO.Action{
            .{ .write = "Found 1 result(s):\n\n" },
            .{ .write = "1. Liftoff News | http://liftoff.msfc.nasa.gov/ | " ++ url ++ "\n" },
            .{ .write = enter_nr },
            .{ .read = "1\n" },
            .{ .write = "Deleted feed '" ++ url ++ "'\n" },
        };
        var text_io = TestIO{
            .do_print = do_print,
            .expected_actions = &actions,
        };

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.deleteFeed("rss2");
    }

    const AllCounts = struct {
        feed: u32,
        item: u32,
        update_http: u32,
        update_local: u32,
    };

    // test that local and url feeds where deleted
    {
        const all_counts_query =
            \\ select
            \\ count(feed.id) as feed,
            \\ count(item.feed_id) as item,
            \\ count(feed_update_local.feed_id) as update_http,
            \\ count(feed_update_http.feed_id) as update_local
            \\ from feed, item, feed_update_local, feed_update_http;
        ;
        const all_counts = try storage.db.one(AllCounts, all_counts_query, .{});
        try expectEqual(AllCounts{ .feed = 0, .item = 0, .update_http = 0, .update_local = 0 }, all_counts.?);
    }
}
