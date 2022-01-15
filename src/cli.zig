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
const FeedDb = @import("feed_db.zig").FeedDb;

pub fn makeCli(
    allocator: Allocator,
    feed_db: *FeedDb,
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

pub const UpdateOptions = struct {
    url: bool = true,
    local: bool = true,
    force: bool = false,
};

pub fn Cli(comptime Writer: type, comptime Reader: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        feed_db: *FeedDb,
        writer: Writer,
        reader: Reader,

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
            const abs_path_err = fs.cwd().realpath(location_input, &path_buf);
            if (abs_path_err) |abs_path| {
                log.info("Add feed: '{s}'", .{abs_path});
                errdefer log.warn("Failed to add local feed: {s}", .{abs_path});
                // Add local feed
                const contents = try shame.getFileContents(self.allocator, abs_path);
                const feed = try parse.parse(self.allocator, contents);
                log.info("\tFeed.items: {}", .{feed.items.len});

                const id = try self.feed_db.addFeed(feed, abs_path);

                const mtime_sec = blk: {
                    const file = try fs.openFileAbsolute(abs_path, .{});
                    defer file.close();
                    const stat = try file.stat();
                    break :blk @intCast(i64, @divFloor(stat.mtime, time.ns_per_s));
                };

                try self.feed_db.addFeedLocal(id, mtime_sec);
                try self.feed_db.addItems(id, feed.items);
                try self.feed_db.cleanItemsByFeedId(id);
                try self.writer.print("Added local feed: {s}", .{abs_path});
            } else |err| switch (err) {
                error.FileNotFound => {
                    log.info("Add feed: '{s}'", .{location_input});
                    errdefer log.warn("Failed to add url feed: {s}", .{location_input});
                    const url = try resolveLocation(self.allocator, location_input);
                    log.info("url: '{s}?{s}'", .{ url.path, url.query });

                    const resp = try resolveRequestToFeed(self.allocator, url, self.writer, self.reader);
                    if (resp.body == null or resp.body.?.len == 0) {
                        log.warn("No body to parse", .{});
                        return error.NoBody;
                    }

                    // Parse feed data
                    const feed = switch (resp.content_type) {
                        .xml_atom => try parse.Atom.parse(self.allocator, resp.body.?),
                        .xml_rss => try parse.Rss.parse(self.allocator, resp.body.?),
                        .xml => try parse.parse(self.allocator, resp.body.?),
                        .unknown => {
                            log.warn("Unknown content type was returned\n", .{});
                            return error.UnknownHttpContent;
                        },
                        .html => unreachable,
                    };

                    const location = blk: {
                        if (resp.url.query.len == 0) {
                            break :blk try fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{
                                resp.url.scheme,
                                resp.url.host.name,
                                resp.url.path,
                            });
                        } else {
                            break :blk try fmt.allocPrint(self.allocator, "{s}://{s}{s}?{s}", .{
                                resp.url.scheme,
                                resp.url.host.name,
                                resp.url.path,
                                resp.url.query,
                            });
                        }
                    };
                    defer self.allocator.free(location);

                    // Add feed
                    const feed_id = try self.feed_db.addFeed(feed, location);
                    try self.feed_db.addFeedUrl(feed_id, resp);
                    try self.feed_db.addItems(feed_id, feed.items);
                    try self.feed_db.cleanItemsByFeedId(feed_id);

                    try self.writer.print("Added url feed: {s}\n", .{location});
                },
                else => return err,
            }
        }

        fn resolveLocation(allocator: Allocator, location: []const u8) !Uri {
            var url = try http.makeUri(location);
            if (std.ascii.endsWithIgnoreCase(url.host.name, "reddit.com")) {
                log.info("reddit.com", .{});
                const path_end = ".rss";
                const path = url.path;
                url.host.name = "old.reddit.com";
                if (url.query.len == 0) url.query = "sort=new";
                if (!std.ascii.endsWithIgnoreCase(path, ".rss")) {
                    log.info("add .rss", .{});
                    url.path = try fmt.allocPrint(allocator, "{s}/{s}", .{ path, path_end });
                }
            }

            return url;
        }

        fn resolveRequestToFeed(
            allocator: Allocator,
            url: Uri,
            writer: anytype,
            reader: anytype,
        ) anyerror!http.FeedResponse {
            const req = http.FeedRequest{ .url = url };
            const resp = try http.resolveRequest(allocator, req);

            if (resp.content_type == .html) {
                const page_data = try parse.Html.parseLinks(allocator, resp.body.?);
                log.info("{}", .{page_data.links.len});
                if (page_data.links.len == 0) {
                    // log.err("Found no RSS or Atom feed links", .{});
                    try writer.print("Found no RSS or Atom feed links\n", .{});
                    return error.NoRssOrAtomLinksFound;
                }
                const link = blk: {
                    const index = try chooseFeedLink(page_data.links.len, writer, reader);
                    break :blk page_data.links[index];
                };
                var rss_uri = try http.makeUri(link.href);
                if (rss_uri.host.name.len == 0) {
                    rss_uri.scheme = resp.url.scheme;
                    rss_uri.host.name = resp.url.host.name;
                }
                return try resolveRequestToFeed(allocator, rss_uri, writer, reader);
            }

            return resp;
        }

        const FeedData = union(enum) {
            host_feeds: []const Host.Feed,
            page_links: []const parse.Html.Link,
        };

        fn printFeedChoices(title: ?[]const u8, url: Uri, feed_data: FeedData, fill_text: []const u8, writer: anytype) !void {
            try writer.print("Choose feed to add\n", .{});
            const feed_title = title orelse "<no-page-title>";
            try writer.print("{s}\n{s}\n", .{ feed_title, url.host.name });
            switch (feed_data) {
                .host_feeds => |feeds| {
                    for (feeds) |feed, i| {
                        try writer.print("\t{d}. {s}{s}{s} -> {s}{s}{s}\n", .{
                            i + 1,
                            feed.title.start,
                            fill_text,
                            feed.title.end,
                            feed.link.start,
                            fill_text,
                            feed.link.end,
                        });
                    }
                },
                .page_links => |_| {
                    //
                },
            }
        }

        fn chooseFeedLink(
            nr_of_links: usize,
            writer: anytype,
            reader: anytype,
        ) !usize {
            var buf: [64]u8 = undefined;
            const result_index = blk: {
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
                    if (nr < 1 or nr > nr_of_links) {
                        try writer.print(
                            "Number out of range: '{d}'. Try again.\n",
                            .{nr},
                        );
                        continue;
                    }
                    break :blk nr - 1;
                }
            };

            return result_index;

            // switch (feed_data) {
            //     .page => |page| {
            //         try writer.print("Choose feed to add\n", .{});
            //         const title = page.title orelse "<no-page-title>";
            //         try writer.print("{s}\n{s}\n", .{ title, url.host.name });
            //         for (page.links) |link, i| {
            //             const link_title = page.links[i].title orelse "<no-title>";
            //             if (link.href[0] != '/') {
            //                 try writer.print("\t{d}. {s} -> {s}\n", .{ i + 1, link_title, link.href });
            //             } else {
            //                 try writer.print("\t{d}. {s} -> {s}://{s}{s}\n", .{
            //                     i + 1,
            //                     link_title,
            //                     url.scheme,
            //                     url.host.name,
            //                     link.href,
            //                 });
            //             }
            //         }

            //         var buf: [64]u8 = undefined;
            //         const result_index = blk: {
            //             while (true) {
            //                 try writer.print("Enter link number: ", .{});
            //                 const bytes = try reader.read(&buf);
            //                 const input = buf[0 .. bytes - 1];
            //                 const nr = fmt.parseUnsigned(u16, input, 10) catch |err| {
            //                     try writer.print(
            //                         "Invalid number: '{s}'. Try again.\n",
            //                         .{input},
            //                     );
            //                     continue;
            //                 };
            //                 if (nr < 1 or nr > page.links.len) {
            //                     try writer.print(
            //                         "Number out of range: '{d}'. Try again.\n",
            //                         .{nr},
            //                     );
            //                     continue;
            //                 }
            //                 break :blk nr - 1;
            //             }
            //         };

            //         return result_index;
            //     },
            //     .host => |host| {
            //         log.info("{}", .{host});
            //         return 0;
            //     },
            // }
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
            self.feed_db.cleanItems(self.allocator) catch {
                log.warn("Failed to remove extra feed items.", .{});
                return;
            };
            try self.writer.print("Clean feeds of extra links/items.\n", .{});
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

        pub fn updateFeeds(self: *Self, opts: UpdateOptions) !void {
            if (opts.url) {
                self.feed_db.updateUrlFeeds(self.allocator, .{ .force = opts.force }) catch {
                    log.err("Failed to update feeds", .{});
                    return;
                };
                try self.writer.print("Updated url feeds\n", .{});
            }
            if (opts.local) {
                self.feed_db.updateLocalFeeds(self.allocator, .{ .force = opts.force }) catch {
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

fn expectCounts(feed_db: *FeedDb, counts: TestCounts) !void {
    const feed_count_query = "select count(id) from feed";
    const local_count_query = "select count(feed_id) from feed_update_local";
    const url_count_query = "select count(feed_id) from feed_update_http";
    const item_count_query = "select count(DISTINCT feed_id) from item";

    const feed_count = try db.count(&feed_db.db, feed_count_query);
    const local_count = try db.count(&feed_db.db, local_count_query);
    const url_count = try db.count(&feed_db.db, url_count_query);
    const item_feed_count = try db.count(&feed_db.db, item_count_query);
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

    var feed_db = try FeedDb.init(allocator, null);

    var cli = Cli(TestIO.Writer, TestIO.Reader){
        .allocator = allocator,
        .feed_db = &feed_db,
        .writer = undefined,
        .reader = undefined,
    };

    {
        const location = "test/sample-rss-2.xml";
        const rss_url = "/media/hdd/code/feed_app/test/sample-rss-2.xml";
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
                .{ .write = "Liftoff News\n  link: http://liftoff.msfc.nasa.gov/\n  location: /media/hdd/code/feed_app/test/sample-rss-2.xml\n\n" },
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
    const allocator = &arena.allocator;

    var feed_db = try FeedDb.init(allocator, null);
    // TODO: populate db with data

    var cli = Cli(TestIO.Writer, TestIO.Reader){
        .allocator = allocator,
        .feed_db = &feed_db,
        .writer = undefined,
        .reader = undefined,
    };

    var first = "Clean feeds of extra links/items.\n";
    var text_io = TestIO{
        .expected_actions = &[_]TestIO.Action{.{ .write = first }},
    };

    cli.writer = text_io.writer();
    try cli.cleanItems();
}

test "local: Cli.addFeed(), Cli.deleteFeed(), Cli.updateFeeds()" {
    const g = @import("feed_db.zig").g;
    std.testing.log_level = .debug;

    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var feed_db = try FeedDb.init(allocator, null);
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
        const rss_url = "/media/hdd/code/feed_app/test/sample-rss-2.xml";
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

        cli.writer = text_io.writer();
        cli.reader = text_io.reader();
        try cli.deleteFeed("liftoff");
        counts.feed -= 1;
        counts.local -= 1;
    }

    try expectCounts(&feed_db, counts);
}

test "url: Cli.addFeed(), Cli.deleteFeed(), Cli.updateFeeds()" {
    std.testing.log_level = .debug;
    const g = @import("feed_db.zig").g;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var feed_db = try FeedDb.init(allocator, null);
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

// When deallocing have to check if input and output urls are different.
// Because no allocations will be made if url is valid
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
    return url;
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
    const html_data = if (resp == .success and resp.success.content_type == .html)
        try parse.Html.parseLinks(arena.allocator(), resp.success.body)
    else
        null;

    if (html_data) |data| {
        if (data.links.len > 0) {
            // user input
            const new_url = try pickFeedLink(data, resp.success.location, writer, reader);
            // make new http request
            resp = try http.resolveRequest(arena, new_url, null, null);
        } else {
            try writer.print("Found no feed links in html\n", .{});
        }
    }

    return resp;
}

test "getFeedHttp()" {
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

pub fn addFeedHttp(allocator: Allocator, feed_db: *FeedDb, input_url: []const u8, writer: anytype, reader: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const url = try makeValidUrl(arena.allocator(), input_url);
    try writer.print("Adding feed '{s}'\n", .{url});
    errdefer writer.print("Failed to add new feed {s}", .{url}) catch unreachable;
    const resp = try getFeedHttp(&arena, url, writer, reader);
    if (resp != .success) {
        try writer.print("Failed to resolve url {s}", .{url});
        if (resp == .fail) {
            try writer.print("Failed message: {s}\n", .{resp.fail});
        }
        return error.FailedHttpRequest;
    }
    if (!mem.eql(u8, url, resp.success.location)) {
        try writer.print(" New url '{s}'\n", .{resp.success.location});
    }
    try writer.print("  Feed fetched\n", .{});

    try writer.print("  Parsing feed\n", .{});
    var feed = try parseFeedResponseBody(&arena, resp.success.body, resp.success.content_type);
    try writer.print("  Feed parsed\n", .{});

    try writer.print("  Saving feed\n", .{});
    if (feed.link == null) feed.link = url;
    // TODO?: make into transaction?
    const feed_id = try feed_db.addFeed(feed, resp.success.location);
    try feed_db.addFeedUrl(feed_id, resp.success);
    try feed_db.addItems(feed_id, feed.items);
    try writer.print("  Feed saved\n", .{});
    parse.printFeed(feed);
}

test "@active addFeedHttp()" {
    const base_allocator = std.testing.allocator;

    var enter_link = "Enter link number: ";
    var read_one = "1\n";

    const url = "https://lobste.rs/";
    var text_io = TestIO{
        .do_print = true,
        .expected_actions = &[_]TestIO.Action{
            .{ .write = "Adding feed '" ++ url ++ "'\n" }, .{ .write = "  Feed fetched\n" },
            .{ .write = "  Parsing feed\n" },              .{ .write = "  Feed parsed\n" },
            .{ .write = "  Saving feed\n" },               .{ .write = "  Feed saved\n" },
            .{ .write = enter_link },                      .{ .read = read_one },
        },
    };
    const writer = text_io.writer();
    const reader = text_io.reader();
    var feed_db = try FeedDb.init(base_allocator, null);

    try addFeedHttp(base_allocator, &feed_db, url, writer, reader);
}
