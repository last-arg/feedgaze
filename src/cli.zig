const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const ascii = std.ascii;
const log = std.log;
const parse = @import("parse.zig");
const http = @import("http.zig");
const Uri = @import("zuri").Uri;
const url_util = @import("url.zig");
const f = @import("feed.zig");
const time = std.time;
const fmt = std.fmt;
const mem = std.mem;
const print = std.debug.print;
const db = @import("db.zig");
const shame = @import("shame.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const assert = std.debug.assert;
const Storage = @import("feed_db.zig").Storage;
const curl = @import("curl_extend.zig");

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
    // TODO: keep or remove url and local?
    url: bool = true,
    local: bool = true,
    force: bool = false,
    default: ?i32 = null,
};

pub const PrintAction = enum { feeds, items };
pub const TagActionCmd = enum { add, remove };
pub const TagArgs = struct {
    action: TagActionCmd,
    url: ?[]const u8 = null,
    id: ?u64 = null,
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
            tags: [][]const u8,
        ) !void {
            var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
            for (locations) |location| {
                if (self.options.local) {
                    if (fs.cwd().realpath(location, &path_buf)) |abs_path| {
                        try self.addFeedLocal(abs_path, tags);
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
                    self.addFeedHttp(location, tags) catch |err| {
                        log.err("Failed to add url feed '{s}'.", .{location});
                        log.err("Error: '{s}'.", .{err});
                    };
                }
            }
        }

        pub fn addFeedLocal(self: *Self, abs_path: []const u8, tags: [][]const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feed = blk: {
                const contents = try shame.getFileContents(arena.allocator(), abs_path);
                const ext = fs.path.extension(abs_path);
                if (mem.eql(u8, ".xml", ext)) {
                    break :blk try parse.parse(&arena, contents);
                } else if (mem.eql(u8, ".atom", ext)) {
                    break :blk try parse.Atom.parse(&arena, contents);
                } else if (mem.eql(u8, ".json", ext)) {
                    break :blk try parse.Json.parse(&arena, contents);
                } else if (mem.eql(u8, ".rss", ext)) {
                    break :blk try parse.Json.parse(&arena, contents);
                }
                log.err("Unhandled file type '{s}'", .{ext});
                return error.UnhandledFileType;
            };

            const mtime_sec = blk: {
                const file = try fs.openFileAbsolute(abs_path, .{});
                defer file.close();
                const stat = try file.stat();
                break :blk @intCast(i64, @divFloor(stat.mtime, time.ns_per_s));
            };

            var savepoint = try self.feed_db.db.sql_db.savepoint("addFeedLocal");
            defer savepoint.rollback();
            const id = try self.feed_db.insertFeed(feed, abs_path);
            try self.feed_db.addFeedLocal(id, mtime_sec);
            try self.feed_db.addItems(id, feed.items);
            try self.feed_db.addTags(id, tags);
            savepoint.commit();
        }

        pub fn addFeedHttp(self: *Self, input_url: []const u8, tags: [][]const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const writer = self.writer;
            var start_url = try url_util.makeValidUrl(arena.allocator(), input_url);
            try curl.globalInit();
            defer curl.globalCleanup();
            var url = start_url;
            var last_header: []const u8 = "";
            var content_type: http.ContentType = .unknown;
            var resp: ?http.Response = null;
            defer if (resp) |*r| r.deinit();
            var tries_left: u8 = 3;
            while (tries_left > 0) : (tries_left -= 1) {
                try writer.print("Fetching feed {s}\n", .{url});
                var tmp_resp = http.resolveRequestCurl(&arena, url, .{}) catch |err| {
                    log.warn("Failed to resolve link '{s}'. Error: {s}", .{ url, @errorName(err) });
                    return;
                };
                // defer tmp_resp.deinit();
                url = tmp_resp.url orelse url;
                if (tmp_resp.status_code != 200) {
                    log.warn("Failed to resolve link '{s}'. Failed HTTP status code: {d}", .{ url, tmp_resp.status_code });
                    return;
                }

                last_header = curl.getLastHeader(tmp_resp.headers_fifo.readableSlice(0));

                var content_type_value = curl.getHeaderValue(last_header, "content-type:") orelse {
                    log.warn("Didn't find Content-Type header. From url '{s}'", .{url});
                    return;
                };

                content_type = http.ContentType.fromString(content_type_value);
                if (content_type == .unknown) {
                    log.warn("Unhandled Content-Type '{s}'. From url '{s}'", .{ content_type_value, url });
                    return;
                }

                if (content_type == .html) {
                    const body = tmp_resp.body_fifo.readableSlice(0);
                    const page = try parse.Html.parseLinks(arena.allocator(), body);
                    if (page.links.len == 0) {
                        log.warn("Could not find any feed links. From url {s}", .{url});
                        return;
                    }

                    const uri = try Uri.parse(url, true);
                    try printPageLinks(self.writer, page, uri);
                    const link_index = try getValidInputNumber(self.reader, self.writer, page.links.len, self.options.default);
                    url = try url_util.makeWholeUrl(arena.allocator(), uri, page.links[link_index].href);
                    tmp_resp.deinit();
                    continue;
                }

                resp = tmp_resp;
                break;
            } else {
                log.warn("Failed to find feed link(s) from url '{s}'", .{url});
                return;
            }

            if (resp == null) {
                log.warn("Failed to get response from HTTP request. From url '{s}'", .{url});
                return;
            }

            const feed = f.Feed.initParse(&arena, url, resp.?.body_fifo.readableSlice(0), content_type) catch {
                log.warn("Can't parse mimetype {s}'s body. From url {s}", .{ content_type, url });
                return;
            };
            var feed_update = try f.FeedUpdate.fromHeadersCurl(last_header);
            _ = try self.feed_db.addNewFeed(feed, feed_update, tags);

            try writer.print("Feed added '{s}'\n", .{url});
        }

        pub fn deleteFeed(self: *Self, search_inputs: [][]const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const results = try self.feed_db.search(arena.allocator(), search_inputs);

            if (results.len == 0) {
                try self.writer.print("Found no matches for '{s}' to delete.\n", .{search_inputs});
                return;
            }
            try self.writer.print("Found {} result(s):\n", .{results.len});
            for (results) |result, i| {
                const link = result.link orelse "<no-link>";
                try self.writer.print("  {}. {s} | {s} | {s}\n", .{
                    i + 1,
                    result.title,
                    link,
                    result.location,
                });
            }
            const index = try getValidInputNumber(self.reader, self.writer, results.len, self.options.default);
            const result = results[index];
            try self.feed_db.deleteFeed(result.id);
            try self.writer.print("Deleted feed '{s}'\n", .{result.location});
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
                try curl.globalInit();
                defer curl.globalCleanup();
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
                id: u64,
                title: []const u8,
                location: []const u8,
                link: ?[]const u8,
            };
            const query = "SELECT id, title, location, link FROM feed;";
            var stmt = try self.feed_db.db.sql_db.prepare(query);
            defer stmt.deinit();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const all_items = stmt.all(Result, arena.allocator(), .{}, .{}) catch |err| {
                log.warn("{s}\nFailed query:\n{s}", .{ self.feed_db.db.sql_db.getDetailedError().message, query });
                return err;
            };

            if (all_items.len == 0) {
                try self.writer.print("There are no feeds to print\n", .{});
                return;
            } else if (all_items.len == 1) {
                try self.writer.print("There is 1 feed\n", .{});
            } else {
                try self.writer.print("There are {d} feeds\n", .{all_items.len});
            }

            const print_fmt =
                \\{s}
                \\  link: {s}
                \\  location: {s}
            ;

            for (all_items) |item, i| {
                const link = item.link orelse "<no-link>";
                if (i != 0) try self.writer.writeAll("\n\n");
                try self.writer.print(print_fmt, .{ item.title, link, item.location });

                const tags = try self.feed_db.db.selectAll(struct { tag: []const u8 }, "select tag from feed_tag where feed_id = ?", .{item.id});
                if (tags.len > 0) {
                    try self.writer.print("\n  tags: ", .{});
                    try self.writer.print("{s}", .{tags[0].tag});
                    for (tags[1..]) |tag| {
                        try self.writer.print(", {s}", .{tag.tag});
                    }
                }
            }
        }

        pub fn search(self: *Self, terms: [][]const u8) !void {
            const results = try self.feed_db.search(self.allocator, terms);
            if (results.len == 0) {
                try self.writer.print("Found no matches\n", .{});
                return;
            } else if (results.len == 1) {
                try self.writer.print("Found 1 match:\n", .{});
            } else {
                try self.writer.print("Found {d} matches:\n", .{results.len});
            }

            for (results) |result| {
                try self.writer.print("{s}\n  id: {}\n  link: {s}\n  feed link: {s}\n", .{ result.title, result.id, result.link, result.location });
            }
        }

        pub fn tagCmd(self: *Self, tags: [][]const u8, args: TagArgs) !void {
            switch (args.action) {
                .add => {
                    if (args.id) |id| {
                        try self.feed_db.addTagsById(tags, id);
                    } else {
                        if (args.url) |url| {
                            try self.feed_db.addTagsByLocation(tags, url);
                        }
                    }
                },
                .remove => {
                    if (args.id) |id| {
                        try self.feed_db.removeTagsById(tags, id);
                    } else {
                        if (args.url) |url| {
                            try self.feed_db.removeTagsByLocation(tags, url);
                        }
                    }
                },
            }
        }

        pub fn printCmd(self: *Self, action: ?PrintAction, tags: ?[][]const u8) !void {
            if (action == null and tags != null and tags.?.len == 0) {
                const all_tags = try self.feed_db.getAllTags();
                try self.writer.print("All tags ({d}):\n", .{all_tags.len});
                for (all_tags) |tag| {
                    try self.writer.print("{s} ({d})\n", .{ tag.name, tag.count });
                }
            }

            if (action) |a| switch (a) {
                .feeds => {
                    try self.printFeeds();
                },
                .items => {
                    try self.printAllItems();
                },
            };
        }
    };
}

fn testAddFeed(storage: *Storage, locations: [][]const u8, expected: ?[]const u8) !void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var cli = Cli(@TypeOf(fbs).Writer, @TypeOf(fbs).Reader){
        .allocator = std.testing.allocator,
        .feed_db = storage,
        .writer = fbs.writer(),
        .reader = fbs.reader(),
    };
    if (expected) |e| mem.copy(u8, fbs.buffer, e);
    try cli.addFeed(locations, "");
    if (expected) |e| try expectEqualStrings(e, fbs.getWritten());
}

// TODO: test update (updateFeeds)
test "local and url: add, update, delete, html links, print" {
    std.testing.log_level = .debug;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = try Storage.init(allocator, null);

    // Test adding file and link (html)
    // Command: feedgaze add test/rss2.xml http://localhost:8080/many-links.html
    const abs_path = "/media/hdd/code/feedgaze/test/rss2.xml";
    const url = "http://localhost:8080/many-links.html";
    {
        var local = abs_path;
        var locations = &.{ local, url };
        const expected_local = "Added local feed: " ++ abs_path ++ "\n";
        const expected_url = comptime fmt.comptimePrint(
            \\Fetching feed {s}
            \\Parse Feed Links | http://localhost:8080/many-links.html
            \\  1. [RSS] Rss 2 http://localhost:8080/rss2.rss
            \\  2. [Unknown] Rss 2 http://localhost:8080/rss2.xml
            \\  3. [Atom] Atom feed http://localhost:8080/atom.atom
            \\  4. [Atom] Not Duplicate http://localhost:8080/rss2.rss
            \\  5. [Unknown] Atom feed http://localhost:8080/atom.xml
            \\Enter link number: <no-number>
            \\Invalid number: '<no-number>'. Try again.
            \\Enter link number: 111
            \\Number out of range: '111'. Try again.
            \\Enter link number: 2
            \\Fetching feed http://localhost:8080/rss2.xml
            \\Feed added 'http://localhost:8080/rss2.xml'
            \\
        , .{url});
        const expected = expected_local ++ expected_url;
        try testAddFeed(&storage, locations, expected);
    }

    const Counts = struct { feed_count: u32, local_count: u32, url_count: u32, item_count: u32 };
    const count_query =
        \\select
        \\  (select count(id) from feed) as feed_count,
        \\  (select count(feed_id) from feed_update_local) as local_count,
        \\  (select count(feed_id) from feed_update_http) as url_count,
        \\  (select count(feed_id) from item) as item_coutn
        \\;
    ;

    // Test row count in feed, feed_update_local and feed_update_http tables
    {
        const counts = try storage.db.one(Counts, count_query, .{});
        try expectEqual(@as(usize, 2), counts.?.feed_count);
        try expectEqual(@as(usize, 1), counts.?.local_count);
        try expectEqual(@as(usize, 1), counts.?.url_count);
    }

    const FeedResult = struct {
        id: u64,
        title: []const u8,
        link: ?[]const u8,
        updated_raw: ?[]const u8,
        updated_timestamp: ?i64,
    };

    var local_id: u64 = undefined;
    var url_id: u64 = undefined;

    // Added local and url feed are the same
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

    const ItemResult = struct {
        title: []const u8,
        link: ?[]const u8,
        guid: ?[]const u8,
        pub_date: ?[]const u8,
        pub_date_utc: ?i64,
    };

    // Added local and url feed items are same
    const item_query = "select title,link,guid,pub_date,pub_date_utc from item where feed_id = ? order by id DESC";
    {
        const local_items = try storage.db.selectAll(ItemResult, item_query, .{local_id});
        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, 6), local_items.len);
        try expectEqual(@as(usize, 6), url_items.len);
        for (local_items) |l_item, i| {
            // const l_item = local_items[0];
            const u_item = url_items[i];
            try std.testing.expectEqualStrings(l_item.title, u_item.title);
            if (l_item.link) |link| try std.testing.expectEqualStrings(link, u_item.link.?);
            if (l_item.guid) |guid| try std.testing.expectEqualStrings(guid, u_item.guid.?);
            if (l_item.pub_date) |pub_date| try std.testing.expectEqualStrings(pub_date, u_item.pub_date.?);
            if (l_item.pub_date_utc) |pub_date_utc| try std.testing.expectEqual(pub_date_utc, u_item.pub_date_utc.?);
        }
    }

    // Test: feedgaze clean
    {
        try storage.cleanItems();
        const local_items = try storage.db.selectAll(ItemResult, item_query, .{local_id});
        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, 6), local_items.len);
        try expectEqual(@as(usize, 6), url_items.len);
    }

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var cli = Cli(@TypeOf(fbs).Writer, @TypeOf(fbs).Reader){
        .allocator = std.testing.allocator,
        .feed_db = &storage,
        .writer = fbs.writer(),
        .reader = fbs.reader(),
    };

    // Test: feedgaze delete rss2
    const enter_nr = "Enter link number:";
    const feed_url = "http://localhost:8080/rss2.xml";
    {
        const expected = fmt.comptimePrint(
            \\Found 2 result(s):
            \\  1. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
            \\  2. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
            \\{s} 1a
            \\Invalid number: '1a'. Try again.
            \\{s} 14
            \\Number out of range: '14'. Try again.
            \\{s} 1
            \\Deleted feed '{s}'
            \\
        , .{ abs_path, feed_url, enter_nr, enter_nr, enter_nr, abs_path });

        fbs.reset();
        mem.copy(u8, fbs.buffer, expected);
        var value: []const u8 = "rss2";
        var values: [][]const u8 = &[_][]const u8{value};
        try cli.deleteFeed(values);
        try expectEqualStrings(expected, fbs.getWritten());
        const all_counts = try storage.db.one(Counts, count_query, .{});
        const expected_counts = Counts{ .feed_count = 1, .item_count = 6, .url_count = 1, .local_count = 0 };
        try expectEqual(expected_counts, all_counts.?);
    }

    // Test: feedgaze print-items
    {
        const expected = fmt.comptimePrint(
            \\Liftoff News - http://liftoff.msfc.nasa.gov/
            \\  Star City&#39;s Test
            \\  http://liftoff.msfc.nasa.gov/news/2003/news-starcity.asp
            \\
            \\  Sky watchers in Europe, Asia, and parts of Alaska{s}
            \\  <no-link>
            \\
            \\  TEST THIS
            \\  <no-link>
            \\
            \\  Astronauts' Dirty Laundry
            \\  http://liftoff.msfc.nasa.gov/news/2003/news-laundry.asp
            \\
            \\  The Engine That Does More
            \\  http://liftoff.msfc.nasa.gov/news/2003/news-VASIMR.asp
            \\
            \\  TEST THIS1
            \\  <no-link>
            \\
            \\
        , .{" "}); // Because kakoune remove spaces from end of line
        fbs.reset();
        try cli.printAllItems();
        try expectEqualStrings(expected, fbs.getWritten());
    }

    // Test: feedgaze print-feeds
    {
        const expected = fmt.comptimePrint(
            \\There is 1 feed
            \\Liftoff News
            \\  link: http://liftoff.msfc.nasa.gov/
            \\  location: {s}
            \\
            \\
        , .{feed_url});
        fbs.reset();
        try cli.printFeeds();
        try expectEqualStrings(expected, fbs.getWritten());
    }
}

fn printPageLinks(writer: anytype, page: parse.Html.Page, uri: Uri) !void {
    const no_title = "<no-title>";
    const page_title = page.title orelse no_title;
    try writer.print("{s} | ", .{page_title});
    try printUrl(writer, uri, null);
    try writer.print("\n", .{});

    for (page.links) |link, i| {
        const link_title = link.title orelse no_title;
        try writer.print("  {d}. [{s}] {s} ", .{ i + 1, parse.Html.MediaType.toString(link.media_type), link_title });
        if (link.href[0] == '/') {
            try printUrl(writer, uri, link.href);
        } else {
            try writer.print("{s}", .{link.href});
        }
        try writer.print("\n", .{});
    }
}

fn printUrl(writer: anytype, uri: Uri, path: ?[]const u8) !void {
    try writer.print("{s}://{s}", .{ uri.scheme, uri.host.name });
    if (uri.port) |port| {
        if (port != 443 and port != 80) {
            try writer.print(":{d}", .{port});
        }
    }
    const out_path = if (path) |p| p else uri.path;
    try writer.print("{s}", .{out_path});
}

fn getValidInputNumber(reader: anytype, writer: anytype, max_len: usize, default_index: ?i32) !u32 {
    var index = try pickNumber(writer, reader, max_len, default_index);
    while (index == null) {
        index = try pickNumber(writer, reader, max_len, null);
    }
    return index.?;
}

fn pickNumber(writer: anytype, reader: anytype, page_links_len: usize, default_pick: ?i32) !?u32 {
    var buf: [64]u8 = undefined;
    var nr: u32 = 0;
    try writer.print("Enter link number: ", .{});
    if (default_pick) |value| {
        nr = @intCast(u32, value);
        try writer.print("{d}\n", .{value});
    } else {
        const input = try reader.readUntilDelimiter(&buf, '\n');
        const value = std.mem.trim(u8, input, &std.ascii.spaces);
        nr = fmt.parseUnsigned(u32, value, 10) catch {
            try writer.print("Invalid number: '{s}'. Try again.\n", .{input});
            return null;
        };
    }
    if (nr < 1 or nr > page_links_len) {
        try writer.print("Number out of range: '{d}'. Try again.\n", .{nr});
        return null;
    }
    return nr - 1;
}
