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
const expectEqualStrings = std.testing.expectEqualStrings;
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
                try writer.print("Feed already exists. Updating feed {s}\n", .{location});
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
            var buf: [32]u8 = undefined;

            var delete_nr: usize = 0;
            while (true) {
                try self.writer.print("Enter feed number to delete? ", .{});
                const input = try self.reader.readUntilDelimiter(&buf, '\n');
                const value = std.mem.trim(u8, input, &std.ascii.spaces);
                if (value.len == 0) continue;

                if (fmt.parseUnsigned(usize, value, 10)) |nr| {
                    if (nr >= 1 and nr <= results.len) {
                        delete_nr = nr;
                        break;
                    }
                    try self.writer.print("Entered number out of range. Try again.\n", .{});
                    continue;
                } else |_| {
                    try self.writer.print("Invalid number entered: '{s}'. Try again.\n", .{value});
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
            // TODO: fix text for one and multiple
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

test "Cli.printAllItems, Cli.printFeeds" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var feed_db = try Storage.init(allocator, null);
    var cli = Cli(@TypeOf(fbs).Writer, @TypeOf(fbs).Reader){
        .allocator = allocator,
        .feed_db = &feed_db,
        .writer = fbs.writer(),
        .reader = fbs.reader(),
    };

    const location = "test/rss2.xml";
    const rss_url = "/media/hdd/code/feedgaze/test/rss2.xml";
    {
        const expected = fmt.comptimePrint("Added local feed: {s}\n", .{rss_url});
        fbs.reset();
        try cli.addFeed(&.{location});
        try expectEqualStrings(expected, fbs.getWritten());
    }

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

    {
        const expected = fmt.comptimePrint(
            \\There are 1 feed(s)
            \\Liftoff News
            \\  link: http://liftoff.msfc.nasa.gov/
            \\  location: {s}
            \\
            \\
        , .{rss_url});
        fbs.reset();
        try cli.printFeeds();
        try expectEqualStrings(expected, fbs.getWritten());
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

// TODO: use it in deleteFeed fn also if possible
fn pickFeedLink(
    page: parse.Html.Page,
    uri: Uri,
    writer: anytype,
    reader: anytype,
) !u32 {
    const no_title = "<no-title>";
    const page_title = page.title orelse no_title;
    try writer.print("{s} | ", .{page_title});
    try printUrl(writer, uri, null);
    try writer.print("\n", .{});

    for (page.links) |link, i| {
        const link_title = link.title orelse no_title;
        try writer.print("  {d}. [{s}] ", .{ i + 1, parse.Html.MediaType.toString(link.media_type) });
        if (link.href[0] == '/') {
            try printUrl(writer, uri, link.href);
        } else {
            try writer.print("{s}", .{link.href});
        }
        try writer.print(" | {s}\n", .{link_title});
    }

    // TODO?: can input several numbers. Space separated, or both?
    var buf: [64]u8 = undefined;
    const index = blk: {
        while (true) {
            try writer.print("Enter link number: ", .{});
            const input = try reader.readUntilDelimiter(&buf, '\n');
            const value = std.mem.trim(u8, input, &std.ascii.spaces);
            const nr = fmt.parseUnsigned(u16, value, 10) catch {
                try writer.print("Invalid number: '{s}'. Try again.\n", .{input});
                continue;
            };
            if (nr < 1 or nr > page.links.len) {
                try writer.print("Number out of range: '{d}'. Try again.\n", .{nr});
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
            const index = try pickFeedLink(data, uri, writer, reader);
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

test "local and url: add, update, delete, html links, add into update" {
    const g = @import("feed_db.zig").g;
    std.testing.log_level = .debug;

    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var storage = try Storage.init(allocator, null);
    var cli = Cli(@TypeOf(fbs).Writer, @TypeOf(fbs).Reader){
        .allocator = allocator,
        .feed_db = &storage,
        .writer = fbs.writer(),
        .reader = fbs.reader(),
    };

    // local 'test/rss2.xml' and url 'http://localhost:8080/rss2.rss' have same content

    // Test add local feed
    // ./feedgaze add test/rss2.xml
    const rel_path = "test/rss2.xml";
    const abs_path = "/media/hdd/code/feedgaze/" ++ rel_path;
    {
        g.max_items_per_feed = 1;
        const expected = "Added local feed: " ++ abs_path ++ "\n";
        // Copying is required when reading from stdout
        mem.copy(u8, fbs.buffer, expected);
        try cli.addFeed(&.{rel_path});
        try expectEqualStrings(expected, fbs.getWritten());
    }

    // Test add url feed
    // ./feedgaze add http://localhost:8080/rss2.rss
    const url = "http://localhost:8080/rss2.rss";
    {
        g.max_items_per_feed = 2;
        const expected = fmt.comptimePrint(
            \\Adding feed {s}
            \\Feed added {s}
            \\
        , .{url} ** 2);
        fbs.reset();
        try cli.addFeed(&.{url});
        try expectEqualStrings(expected, fbs.getWritten());
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

    // Test if local and url feeds' table fields have same values
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

    // Test row count in feed_update_local and feed_update_http tables
    {
        const feed_url_local_counts_query = "select count(feed_update_local.feed_id) as local_count, count(feed_update_http.feed_id) as url_count from feed_update_local, feed_update_http";
        const counts = try storage.db.one(struct { local_count: u32, url_count: u32 }, feed_url_local_counts_query, .{});
        try expectEqual(@as(usize, 1), counts.?.local_count);
        try expectEqual(@as(usize, 1), counts.?.url_count);
    }

    // Test if two (local and url) feeds' first(newest) items are same
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
    // Test parsing links from html
    // Test feed already existing
    // ./feedgaze add http://localhost:8080/many-links.html
    {
        const html_url = "http://localhost:8080/many-links.html";
        const expected =
            \\Adding feed http://localhost:8080/many-links.html
            \\Parse Feed Links | http://localhost:8080/many-links.html
            \\  1. [RSS] http://localhost:8080/rss2.rss | Rss 2
            \\  2. [Unknown] http://localhost:8080/rss2.xml | Rss 2
            \\  3. [Atom] http://localhost:8080/atom.atom | Atom feed
            \\  4. [Atom] http://localhost:8080/rss2.rss | Not Duplicate
            \\  5. [Unknown] http://localhost:8080/atom.xml | Atom feed
            \\Enter link number: 1
            \\Feed already exists. Updating feed http://localhost:8080/rss2.rss
            \\Feed updated http://localhost:8080/rss2.rss
            \\
        ;

        fbs.reset();
        // Copying is required when reading from stdout
        mem.copy(u8, fbs.buffer, expected);
        try cli.addFeed(&.{html_url});
        try expectEqualStrings(expected, fbs.getWritten());
        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, 6), url_items.len);
    }

    // Test update feeds
    // ./feedgaze update
    {
        const expected =
            \\Updated url feeds
            \\Updated local feeds
            \\
        ;
        fbs.reset();
        cli.options.force = true;
        try cli.updateFeeds();
        cli.options.force = false;

        try expectEqualStrings(expected, fbs.getWritten());
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

    // Test clean items
    // ./feedgaze clean
    {
        g.max_items_per_feed = 2;
        try storage.cleanItems();
        const local_items = try storage.db.selectAll(ItemResult, item_query, .{local_id});
        const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
        try expectEqual(@as(usize, g.max_items_per_feed), local_items.len);
        try expectEqual(@as(usize, g.max_items_per_feed), url_items.len);
    }

    // Test delete local feed
    // ./feedgaze delete rss2
    const enter_nr = "Enter feed number to delete?";
    {
        const expected = fmt.comptimePrint(
            \\Found 2 result(s):
            \\  1. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
            \\  2. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
            \\{s} 1a
            \\Invalid number entered: '1a'. Try again.
            \\{s} 14
            \\Entered number out of range. Try again.
            \\{s} 1
            \\Deleted feed '{s}'
            \\
        , .{ abs_path, url, enter_nr, enter_nr, enter_nr, abs_path });
        fbs.reset();
        mem.copy(u8, fbs.buffer, expected);
        cli.deleteFeed("rss2") catch print("|{s}|\n", .{fbs.getWritten()});
        try expectEqualStrings(expected, fbs.getWritten());
    }

    // Test delete url feed
    // ./feedgaze delete rss2
    {
        const expected = fmt.comptimePrint(
            \\Found 1 result(s):
            \\  1. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
            \\{s} 1
            \\Deleted feed '{s}'
            \\
        , .{ url, enter_nr, url });
        fbs.reset();
        mem.copy(u8, fbs.buffer, expected);
        try cli.deleteFeed("rss2");
        try expectEqualStrings(expected, fbs.getWritten());
    }

    const AllCounts = struct {
        feed: u32,
        item: u32,
        update_http: u32,
        update_local: u32,
    };

    // Test that local and url feeds were deleted
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
