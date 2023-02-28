const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Storage = @import("./storage.zig").Storage;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const FeedUpdate = feed_types.FeedUpdate;
const FeedToUpdate = feed_types.FeedToUpdate;
const print = std.debug.print;
const parse = @import("./app_parse.zig");
const FeedAndItems = parse.FeedAndItems;
const ContentType = parse.ContentType;
const builtin = @import("builtin");
const args_parser = @import("zig-args");
const ShowOptions = feed_types.ShowOptions;
const FetchOptions = feed_types.FetchOptions;

pub const Response = struct {
    feed_update: FeedUpdate,
    content: []const u8,
    content_type: ContentType,
    location: []const u8,
};

const UpdateOptions = struct {
    force: bool = false,
};

const CliVerb = union(enum) {
    add: void,
    remove: void,
    show: ShowOptions,
    update: UpdateOptions,
};

pub fn Cli(comptime Out: anytype) type {
    return struct {
        allocator: Allocator,
        storage: Storage,
        clean_opts: Storage.CleanOptions = .{},
        out: Out,
        fetchFeedFn: *const fn (*FeedRequest, Allocator, []const u8, FetchOptions) anyerror!FeedRequest.Response = fetchFeed,
        const Self = @This();

        pub fn run(self: *Self) !void {
            // TODO?: use parseWithVerb?
            // Is better for testing purposes
            const options = try args_parser.parseWithVerbForCurrentProcess(struct {}, CliVerb, self.allocator, .print);
            defer options.deinit();

            const verb = options.verb orelse {
                std.log.err("Use valid subcommand: add, remove, update, show", .{});
                return;
            };

            switch (verb) {
                .add => {
                    if (options.positionals.len > 0) {
                        for (options.positionals) |url| {
                            try self.add(url);
                        }
                    } else {
                        std.log.err("'add' subcommand requires feed url.\nExample: feedgaze add <url>", .{});
                    }
                },
                .remove => {
                    if (options.positionals.len > 0) {
                        for (options.positionals) |url| {
                            try self.remove(url);
                        }
                    } else {
                        std.log.err("'remove' subcommand requires search term (feed url).\nExample: feedgaze remove <url>", .{});
                    }
                },
                .show => |opts| {
                    const url = if (options.positionals.len > 0) options.positionals[0] else null;
                    try self.show(url, opts);
                },
                .update => |opts| {
                    const input = if (options.positionals.len > 0) options.positionals[0] else null;
                    try self.update(input, opts);
                },
            }
        }

        pub fn add(self: *Self, url: []const u8) !void {
            if (try self.storage.hasFeedWithFeedUrl(url)) {
                std.log.info("There already exists feed '{s}'", .{url});
                return;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            // fetch url content
            var fr = try FeedRequest.init(arena.allocator());
            defer fr.deinit();
            var resp = try self.fetchFeedFn(&fr, arena.allocator(), url, .{});

            const content_type = resp.headers.content_type orelse return error.NoContentType;
            var parsed = try parse.parse(arena.allocator(), resp.content, content_type);
            if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
                parsed.feed.updated_raw = parsed.items[0].updated_raw;
            }
            try parsed.feed.prepareAndValidate(url);
            const feed_id = try self.storage.insertFeed(parsed.feed);
            try FeedItem.prepareAndValidateAll(parsed.items, feed_id);
            _ = try self.storage.insertFeedItems(parsed.items);
            try self.storage.updateFeedUpdate(FeedUpdate.fromHeaders(resp.headers, feed_id));
        }

        pub fn update(self: *Self, input: ?[]const u8, options: UpdateOptions) !void {
            // TODO: use UpdateOptions
            _ = options;
            if (input == null) {
                std.log.info("Updating all feeds", .{});
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const feed_updates = try self.storage.getFeedsToUpdate(arena.allocator(), input);

            for (feed_updates) |f_update| {
                var fr = try FeedRequest.init(arena.allocator());
                defer fr.deinit();

                var resp = try self.fetchFeedFn(&fr, arena.allocator(), f_update.feed_url, .{
                    .etag = f_update.etag,
                    .last_modified_utc = f_update.last_modified_utc,
                });

                const content_type = resp.headers.content_type orelse .xml;
                var parsed = try parse.parse(arena.allocator(), resp.content, content_type);

                if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
                    parsed.feed.updated_raw = parsed.items[0].updated_raw;
                }

                parsed.feed.feed_id = f_update.feed_id;
                try parsed.feed.prepareAndValidate(f_update.feed_url);
                try self.storage.updateFeed(parsed.feed);

                // Update feed items
                try FeedItem.prepareAndValidateAll(parsed.items, f_update.feed_id);
                try self.storage.updateAndRemoveFeedItems(parsed.items, self.clean_opts);

                // Update feed_update
                try self.storage.updateFeedUpdate(FeedUpdate.fromHeaders(resp.headers, f_update.feed_id));
                std.log.info("Updated feed '{s}'", .{f_update.feed_url});
            }
        }

        pub fn remove(self: *Self, url: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feeds = try self.storage.getFeedsWithUrl(arena.allocator(), url);
            if (feeds.len == 0) {
                std.log.info("Found no feeds for <url> input '{s}'", .{url});
                return;
            }

            for (feeds) |feed| {
                try self.storage.deleteFeed(feed.feed_id);
                std.log.info("Removed feed '{s}'", .{feed.feed_url});
            }
        }

        pub fn show(self: *Self, url: ?[]const u8, opts: ShowOptions) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feeds = try self.storage.getLatestFeedsWithUrl(arena.allocator(), url orelse "", .{});

            for (feeds) |feed| {
                const title = feed.title orelse "<no title>";
                const url_out = feed.page_url orelse feed.feed_url;
                _ = try self.out.print("{s} - {s}\n", .{ title, url_out });
                const items = try self.storage.getLatestFeedItemsWithFeedId(arena.allocator(), feed.feed_id, opts);
                if (items.len == 0) {
                    _ = try self.out.write("  ");
                    _ = try self.out.write("Feed has no items.");
                    continue;
                }

                for (items) |item| {
                    // _ = try self.out.print("{d}. ", .{item.item_id.?});
                    _ = try self.out.print("\n  {s}\n  {s}\n", .{ item.title, item.link orelse "<no link>" });
                }
                _ = try self.out.write("\n");
            }
        }
    };
}

const Uri = std.Uri;
const FeedRequest = @import("./http_client.zig").FeedRequest;
fn fetchFeed(fr: *FeedRequest, allocator: Allocator, url: []const u8, opts: FetchOptions) !FeedRequest.Response {
    _ = allocator;
    const uri = try Uri.parse(url);
    return try fr.fetch(uri, opts);
}

const Test = struct {
    var feed_id: ?usize = null;
    pub fn fetch(fr: *FeedRequest, allocator: Allocator, url: []const u8, opts: FetchOptions) anyerror!FeedRequest.Response {
        _ = fr;
        _ = opts;
        _ = allocator;
        _ = url;
        return .{
            .content = @embedFile("rss2.xml"),
            .headers = .{ .content_type = .rss, .etag = null, .last_modified = null, .max_age = null, .status = .ok },
        };
    }
};

test "cli.run" {
    std.testing.log_level = .debug;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cmd = "feedgaze".*;
    var storage = try Storage.init();
    var buf: [10 * 1024]u8 = undefined;
    var fb = std.io.fixedBufferStream(&buf);
    var fb_writer = fb.writer();
    const CliTest = Cli(@TypeOf(fb_writer));
    var app_cli = CliTest{
        .allocator = arena.allocator(),
        .storage = storage,
        .out = fb_writer,
    };

    // TODO: add flag that only does it when running in linux?
    // TODO: test url redirect
    var input = "http://localhost:8282/rss2.xml".*;
    {
        var add_cmd = "add".*;
        std.os.argv = &[_][*:0]u8{ cmd[0..], add_cmd[0..], input[0..] };
        try app_cli.run();

        const feeds = try storage.getFeedsWithUrl(arena.allocator(), &input);
        try std.testing.expectEqual(@as(usize, 1), feeds.len);
        const feed = feeds[0];
        var expect = try parse.parseRss(arena.allocator(), @embedFile("rss2.xml"));
        try expect.feed.prepareAndValidate(&input);
        expect.feed.feed_id = 1;
        try std.testing.expectEqualDeep(expect.feed, feed);
        const items = try storage.getFeedItemsWithFeedId(arena.allocator(), feed.feed_id);
        try std.testing.expectEqual(@as(usize, 3), items.len);
    }

    {
        // Show feeds and items
        // feedgaze show [<url>] [--limit]
        // - will show latest updated feeds first
        var show_cmd = "show".*;
        std.os.argv = &[_][*:0]u8{ cmd[0..], show_cmd[0..], input[0..] };
        try app_cli.run();
        const r = fb.getWritten();
        // print("|{s}|\n", .{fb.getWritten()});
        const expect =
            \\Liftoff News - http://liftoff.msfc.nasa.gov/
            \\
            \\  Star City's Test
            \\  http://liftoff.msfc.nasa.gov/news/2003/news-starcity.asp
            \\
            \\  Sky watchers in Europe, Asia, and parts of Alaska and Canada will experience a <a href="http://science.nasa.gov/headlines/y2003/30may_solareclipse.htm">partial eclipse of the Sun</a> on Saturday, May 31st.
            \\  <no link>
            \\
            \\  Third title
            \\  <no link>
            \\
            \\
        ;
        try std.testing.expectEqualStrings(expect, r);
    }

    {
        // Update feed
        // feedgaze update <url> [--force]
        // - check if feed with <url> exists
        // - if not --force
        //   - see if feed needs updating
        // - update if needed
        var subcmd = "update".*;
        std.os.argv = &[_][*:0]u8{ cmd[0..], subcmd[0..], input[0..] };
        try app_cli.run();
        var items = try storage.getLatestFeedItemsWithFeedId(arena.allocator(), @as(usize, 1), .{});
        try std.testing.expectEqual(@as(usize, 3), items.len);

        app_cli.clean_opts.max_item_count = 2;
        try app_cli.run();
        app_cli.clean_opts.max_item_count = 10;
        const items1 = try storage.getLatestFeedItemsWithFeedId(arena.allocator(), @as(usize, 1), .{});
        try std.testing.expectEqual(@as(usize, 2), items1.len);
        try std.testing.expectEqual(@as(usize, 2), items1[0].item_id.?);
        try std.testing.expectEqual(@as(usize, 3), items1[1].item_id.?);

        // Delete first item (newest/latest)
        try storage.sql_db.exec("DELETE FROM item WHERE item_id = 1", .{}, .{});

        try app_cli.run();
        var items2 = try storage.getLatestFeedItemsWithFeedId(arena.allocator(), @as(usize, 1), .{});
        try std.testing.expectEqual(@as(usize, 3), items2.len);
        // Set same item_id for equality check. New id because item was added.
        items2[0].item_id = items[0].item_id;
        try std.testing.expectEqualDeep(items2, items);
    }

    {
        var remove_cmd = "remove".*;
        std.os.argv = &[_][*:0]u8{ cmd[0..], remove_cmd[0..], input[0..] };
        try app_cli.run();

        const feeds = try storage.getFeedsWithUrl(arena.allocator(), &input);
        try std.testing.expectEqual(@as(usize, 0), feeds.len);
        var item_count = @import("./storage.zig").one(&storage.sql_db, usize, "select count(*) from item;", .{}) catch unreachable;
        try std.testing.expectEqual(@as(usize, 0), item_count.?);
    }
}
