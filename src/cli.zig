const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const ascii = std.ascii;
const log = std.log;
const parse = @import("parse.zig");
const http = @import("http.zig");
const zfetch = @import("zfetch");
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

var general_request_headers = [_]zfetch.Header{
    .{ .name = "Connection", .value = "close" },
    .{ .name = "Accept-Encoding", .value = "gzip" },
    .{ .name = "Accept", .value = "application/atom+xml, application/rss+xml, application/feed+json, text/xml, application/xml, application/json, text/html" },
};

pub const CliOptions = struct {
    url: bool = true,
    local: bool = true,
    force: bool = false,
    default: ?i32 = null,
};

pub const TagArgs = struct {
    action: enum { add, remove, remove_all, none } = .none,
    location: []const u8 = "",
    id: u64 = 0,
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
            tags: []const u8, // comma separated
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

        pub fn addFeedLocal(self: *Self, abs_path: []const u8, tags: []const u8) !void {
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

        pub fn addFeedHttp(self: *Self, input_url: []const u8, tags: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const writer = self.writer;

            const url = try url_util.makeValidUrl(arena.allocator(), input_url);
            var req: *zfetch.Request = undefined;
            var content_type_value: []const u8 = "";
            var content_type: http.ContentType = .unknown;
            const max_tries = 3;
            var urls_tried_count: usize = 1;
            while (urls_tried_count <= max_tries) : (urls_tried_count += 1) {
                try writer.print("Fetching feed {s}\n", .{url});
                // clean previous request if there is one
                if (urls_tried_count > 1) req.deinit();
                req = try http.resolveRequest2(&arena, url, &general_request_headers);
                if (req.status.code != 200) {
                    switch (req.status.code) {
                        301, 307, 308 => log.warn("Failed request. Too many redirects. Final request location {s}", .{req.url}),
                        else => log.warn("Failed to resolve HTTP request: {d} {s}", .{ req.status.code, req.status.reason }),
                    }
                    return;
                }

                content_type_value = blk: {
                    var value_opt: ?[]const u8 = null;
                    for (req.headers.list.items) |h| {
                        if (ascii.eqlIgnoreCase(h.name, "content-type")) {
                            value_opt = h.value;
                        }
                    }

                    const value = value_opt orelse {
                        log.warn("There is no Content-Type header key. From url {s}", .{req.url});
                        return;
                    };

                    const end = mem.indexOf(u8, value, ";") orelse value.len;
                    break :blk value[0..end];
                };

                content_type = http.ContentType.fromString(content_type_value);
                if (content_type == .unknown) {
                    log.warn("Unhandle Content-Type {s}. From url {s}", .{ content_type_value, req.url });
                    return;
                }

                if (content_type == .html) {
                    const body = try http.getRequestBody(&arena, req);
                    const page = try parse.Html.parseLinks(arena.allocator(), body);
                    if (page.links.len == 0) {
                        log.warn("Found no feed links from returned html page. From url {s}", .{req.url});
                        return;
                    }
                    // TODO: display feed options
                    // TODO: choose feed link
                    // TODO: resolve chosen link

                    // Put url request making into a loop until one of the valid content types is found or
                    // request fails
                    continue;
                }
                break;
            }

            const body = try http.getRequestBody(&arena, req);
            if (body.len == 0) {
                log.warn("No body to parse for feed", .{});
                return;
            }

            const feed = f.Feed.initParse(&arena, url, body, content_type) catch {
                log.warn("Can't parse mimetype {s}'s body. From url {s}", .{ content_type_value, url });
                return;
            };

            var feed_update = try f.FeedUpdate.fromHeaders(req.headers.list.items);
            _ = try self.feed_db.addNewFeed(feed, feed_update, tags);
            try writer.print("Feed added {s}\n", .{req.url});
        }

        pub fn deleteFeed(self: *Self, search_inputs: [][]const u8) !void {
            const results = try self.feed_db.search(self.allocator, search_inputs);

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
            var buf: [32]u8 = undefined;
            var index = try pickNumber(&buf, results.len, self.options.default, self.writer, self.reader);
            while (index == null) {
                index = try pickNumber(&buf, results.len, null, self.writer, self.reader);
            }

            const result = results[index.?];
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
            const all_items = stmt.all(Result, self.allocator, .{}, .{}) catch |err| {
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
                \\
            ;

            for (all_items) |item| {
                const link = item.link orelse "<no-link>";
                try self.writer.print(print_fmt, .{ item.title, link, item.location });

                const tags = try self.feed_db.db.selectAll(struct { tag: []const u8 }, "select tag from feed_tag where feed_id = ?", .{item.id});
                if (tags.len > 0) {
                    try self.writer.print("  tags: ", .{});
                    try self.writer.print("{s}", .{tags[0].tag});
                    for (tags[1..]) |tag| {
                        try self.writer.print(", {s}\n", .{tag.tag});
                    }
                }
                try self.writer.print("\n", .{});
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
            assert(args.id != 0 or args.location.len != 0);
            assert(args.action != .none);

            switch (args.action) {
                .add => {
                    var cap = tags.len - 1; // commas
                    for (tags) |tag| cap += tag.len;
                    var arr_tags = try ArrayList(u8).initCapacity(self.allocator, cap);
                    if (tags.len > 0) {
                        arr_tags.appendSliceAssumeCapacity(tags[0]);
                        for (tags[1..]) |tag| {
                            arr_tags.appendAssumeCapacity(',');
                            arr_tags.appendSliceAssumeCapacity(tag);
                        }
                    }
                    if (args.id != 0) {
                        try self.feed_db.addTagsById(arr_tags.items, args.id);
                    } else if (args.location.len != 0) {
                        try self.feed_db.addTagsByLocation(arr_tags.items, args.location);
                    }
                },
                .remove => {
                    if (args.id != 0) {
                        try self.feed_db.removeTagsById(tags, args.id);
                    } else if (args.location.len != 0) {
                        try self.feed_db.removeTagsByLocation(tags, args.location);
                    }
                },
                .remove_all => try self.feed_db.removeTags(tags),
                .none => unreachable,
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
            \\There is 1 feed
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

fn pickFeedLink(
    page: parse.Html.Page,
    uri: Uri,
    writer: anytype,
    reader: anytype,
    default_pick: ?i32,
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
    var index = try pickNumber(&buf, page.links.len, default_pick, writer, reader);
    while (index == null) {
        index = try pickNumber(&buf, page.links.len, null, writer, reader);
    }
    return index.?;
}

fn pickNumber(buf: []u8, page_links_len: usize, default_pick: ?i32, writer: anytype, reader: anytype) !?u32 {
    var nr: u32 = 0;
    try writer.print("Enter link number: ", .{});
    if (default_pick) |value| {
        nr = @intCast(u32, value);
        try writer.print("{d}\n", .{value});
    } else {
        const input = try reader.readUntilDelimiter(buf, '\n');
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

fn getFeedHttp(arena: *ArenaAllocator, url: []const u8, writer: anytype, reader: anytype, default_pick: ?i32) !http.FeedResponse {
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
            const index = try pickFeedLink(data, uri, writer, reader, default_pick);
            const new_url = try url_util.makeWholeUrl(arena.allocator(), uri, data.links[index].href);
            resp = try http.resolveRequest(arena, new_url, null, null);
        }
    }

    return resp;
}

test "@active url: add" {
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

    // url redirects
    const url = "http://localhost:8080/rss2.rss";
    {
        g.max_items_per_feed = 2;
        const expected = fmt.comptimePrint(
            \\Fetching feed {s}
            \\Feed added {s}
            \\
        , .{ url, url });
        fbs.reset();
        try cli.addFeed(&.{url}, "");
        try expectEqualStrings(expected, fbs.getWritten());
    }
}

// TODO: make tests more self containing
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
        try cli.addFeed(&.{rel_path}, "");
        try expectEqualStrings(expected, fbs.getWritten());
    }

    // Test add url feed
    // ./feedgaze add http://localhost:8080/rss2.rss
    const url = "http://localhost:8080/rss2.rss";
    {
        g.max_items_per_feed = 2;
        const expected = fmt.comptimePrint(
            \\Fetching feed {s}
            \\Feed added {s}
            \\
        , .{url} ** 2);
        fbs.reset();
        try cli.addFeed(&.{url}, "");
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
    // TODO: reenable test
    // {
    //     const html_url = "http://localhost:8080/many-links.html";
    //     const expected =
    //         \\Fetching feed http://localhost:8080/many-links.html
    //         \\Parse Feed Links | http://localhost:8080/many-links.html
    //         \\  1. [RSS] http://localhost:8080/rss2.rss | Rss 2
    //         \\  2. [Unknown] http://localhost:8080/rss2.xml | Rss 2
    //         \\  3. [Atom] http://localhost:8080/atom.atom | Atom feed
    //         \\  4. [Atom] http://localhost:8080/rss2.rss | Not Duplicate
    //         \\  5. [Unknown] http://localhost:8080/atom.xml | Atom feed
    //         \\Enter link number: 1
    //         \\Feed added http://localhost:8080/rss2.rss
    //         \\
    //     ;

    //     fbs.reset();
    //     // Copying is required when reading from stdout
    //     mem.copy(u8, fbs.buffer, expected);
    //     try cli.addFeed(&.{html_url}, "");
    //     try expectEqualStrings(expected, fbs.getWritten());
    //     const url_items = try storage.db.selectAll(ItemResult, item_query, .{url_id});
    //     try expectEqual(@as(usize, 6), url_items.len);
    // }

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
    // const enter_nr = "Enter feed number to delete?";
    // {
    //     const expected = fmt.comptimePrint(
    //         \\Found 2 result(s):
    //         \\  1. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
    //         \\  2. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
    //         \\{s} 1a
    //         \\Invalid number entered: '1a'. Try again.
    //         \\{s} 14
    //         \\Entered number out of range. Try again.
    //         \\{s} 1
    //         \\Deleted feed '{s}'
    //         \\
    //     , .{ abs_path, url, enter_nr, enter_nr, enter_nr, abs_path });
    //     fbs.reset();
    //     mem.copy(u8, fbs.buffer, expected);
    //     var value: []const u8 = "rss2";
    //     var values: [][]const u8 = &[_][]const u8{value};
    //     cli.deleteFeed(values) catch print("|{s}|\n", .{fbs.getWritten()});
    //     try expectEqualStrings(expected, fbs.getWritten());
    // }

    // Test delete url feed
    // ./feedgaze delete rss2
    // {
    //     const expected = fmt.comptimePrint(
    //         \\Found 1 result(s):
    //         \\  1. Liftoff News | http://liftoff.msfc.nasa.gov/ | {s}
    //         \\{s} 1
    //         \\Deleted feed '{s}'
    //         \\
    //     , .{ url, enter_nr, url });
    //     fbs.reset();
    //     mem.copy(u8, fbs.buffer, expected);
    //     var value: []const u8 = "rss2";
    //     var values: [][]const u8 = &[_][]const u8{value};
    //     try cli.deleteFeed(values);
    //     try expectEqualStrings(expected, fbs.getWritten());
    // }

    // const AllCounts = struct {
    //     feed: u32,
    //     item: u32,
    //     update_http: u32,
    //     update_local: u32,
    // };

    // Test that local and url feeds were deleted
    // {
    //     const all_counts_query =
    //         \\ select
    //         \\ count(feed.id) as feed,
    //         \\ count(item.feed_id) as item,
    //         \\ count(feed_update_local.feed_id) as update_http,
    //         \\ count(feed_update_http.feed_id) as update_local
    //         \\ from feed, item, feed_update_local, feed_update_http;
    //     ;
    //     const all_counts = try storage.db.one(AllCounts, all_counts_query, .{});
    //     try expectEqual(AllCounts{ .feed = 0, .item = 0, .update_http = 0, .update_local = 0 }, all_counts.?);
    // }
}
