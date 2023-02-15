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

pub fn Cli(comptime Out: anytype) type {
    return struct {
        allocator: Allocator,
        storage: Storage,
        clean_opts: Storage.CleanOptions = .{},
        out: Out,
        const Self = @This();

        const UpdateOptions = struct {
            search_term: ?[]const u8 = null,
            force: bool = false,
            all: bool = false,
        };

        pub fn add(self: *Self, url: []const u8) !void {
            if (try self.storage.hasFeedWithFeedUrl(url)) {
                std.log.info("There already exists feed '{s}'", .{url});
                return;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            // fetch url content
            var resp = try self.fetchFeed(arena.allocator(), url);
            if (!mem.eql(u8, url, resp.location)) {
                if (try self.storage.hasFeedWithFeedUrl(resp.location)) {
                    std.log.info("There already exists feed '{s}'", .{url});
                    return;
                }
            }

            var parsed = try parse.parse(arena.allocator(), resp.content, resp.content_type);
            if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
                parsed.feed.updated_raw = parsed.items[0].updated_raw;
            }
            try parsed.feed.prepareAndValidate(resp.location);
            const feed_id = try self.storage.insertFeed(parsed.feed);
            try FeedItem.prepareAndValidateAll(parsed.items, feed_id);
            _ = try self.storage.insertFeedItems(parsed.items);
            resp.feed_update.feed_id = feed_id;
            try self.storage.updateFeedUpdate(resp.feed_update);
        }

        pub fn update(self: *Self, options: UpdateOptions) !void {
            if (options.search_term == null and !options.all) {
                std.log.info(
                    \\subcommand 'update' is missing one of required arguments: 
                    \\1) '<url>' search term. Example: 'feedgaze update duckduckgo.com'
                    \\2) flag '--all'. Example: 'feedgaze update --all'
                , .{});
                return error.MissingArgument;
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const feed_updates = blk: {
                if (options.search_term) |url| {
                    break :blk try self.storage.getFeedsToUpdate(arena.allocator(), url);
                }
                // gets all feeds
                break :blk try self.storage.getFeedsToUpdate(arena.allocator(), null);
            };

            for (feed_updates) |f_update| {
                // TODO: fetch update.feed_url content.
                // use updates.expires_utc and updates.last_modified_utc in http header.
                var resp = try self.fetchFeed(arena.allocator(), f_update.feed_url);
                var parsed = try parse.parse(arena.allocator(), resp.content, resp.content_type);

                if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
                    parsed.feed.updated_raw = parsed.items[0].updated_raw;
                }

                parsed.feed.feed_id = f_update.feed_id;
                try self.storage.updateFeed(parsed.feed);

                // Update feed items
                try FeedItem.prepareAndValidateAll(parsed.items, f_update.feed_id);
                try self.storage.updateAndRemoveFeedItems(parsed.items, self.clean_opts);

                // Update feed_update
                try self.storage.updateFeedUpdate(resp.feed_update);
                std.log.info("Updated feed '{s}'", .{f_update.feed_url});
            }
        }

        pub const Response = struct {
            feed_update: FeedUpdate,
            content: []const u8,
            content_type: ContentType,
            location: []const u8,
        };

        fn fetchFeed(self: *Self, allocator: Allocator, url: []const u8) !Response {
            return if (!builtin.is_test) self.fetchFeedImpl(allocator, url) else self.testFetch(allocator, url);
        }

        fn fetchFeedImpl() !Response {
            @panic("TODO: implement fetchFeedImpl fn");
        }

        fn testFetch(self: *Self, allocator: Allocator, url: []const u8) !Response {
            const feeds = try self.storage.getFeedsWithUrl(allocator, url);
            var feed_id: ?usize = null;
            var feed_url = url;
            if (feeds.len > 0) {
                feed_id = feeds[0].feed_id;
            }
            return .{
                .feed_update = FeedUpdate{ .feed_id = feed_id },
                .content = @embedFile("rss2.xml"),
                .content_type = .rss,
                .location = feed_url,
            };
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

        pub const ShowOption = struct {
            limit: usize = 10,
        };
        pub fn show(self: *Self, url: ?[]const u8, opts: ShowOption) !void {
            _ = opts;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feeds = try self.storage.getFeedsWithUrl(arena.allocator(), url orelse "");

            _ = try self.out.write("start\n");

            for (feeds) |feed| {
                _ = feed;
                // _ = try out.writer().write(feed.feed_url);
                _ = try self.out.write("hello\n");
            }
        }
    };
}

test "all" {
    std.testing.log_level = .debug;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = try Storage.init();
    var buf: [10 * 1024]u8 = undefined;
    var fb = std.io.fixedBufferStream(&buf);
    var fb_writer = fb.writer();
    var cli = Cli(@TypeOf(fb_writer)){
        .allocator = arena.allocator(),
        .storage = storage,
        .out = fb_writer,
    };

    const input_url = "http://localhost/valid_url";
    var feed_id: usize = 1;
    {
        // Add feed
        // feedgaze add <url>
        // Setup: add/insert feed and items
        // feedgaze add http://localhost:8282/rss2.xml
        try cli.add(input_url);
        const feeds = try storage.getFeedsWithUrl(arena.allocator(), input_url);
        try std.testing.expectEqual(feed_id, feeds[0].feed_id);
        const items = try storage.getFeedItemsWithFeedId(arena.allocator(), feed_id);
        try std.testing.expectEqual(@as(usize, 3), items.len);
    }

    {
        // Show feeds and items
        // feedgaze show [<url>] [--limit]
        // - will show latest updated feeds first
        try cli.show(input_url, .{});
        const r = fb.getWritten();
        print("|{s}|\n", .{r});
    }

    {
        // Update feed
        // feedgaze update <url> [--force]
        // - check if feed with <url> exists
        // - if not --force
        //   - see if feed needs updating
        // - update if needed
        try cli.update(.{ .search_term = input_url });
        const update_feeds = (try storage.getFeedsWithUrl(arena.allocator(), input_url));
        var items = try storage.getFeedItemsWithFeedId(arena.allocator(), update_feeds[0].feed_id);
        try std.testing.expectEqual(@as(usize, 3), items.len);
        cli.clean_opts.max_item_count = 2;
        try cli.update(.{ .search_term = input_url });
        items = try storage.getFeedItemsWithFeedId(arena.allocator(), update_feeds[0].feed_id);
        try std.testing.expectEqual(@as(usize, 2), items.len);
    }
    cli.clean_opts.max_item_count = 10;

    {
        // Delete feed
        // feedgaze remove <url>
        try cli.remove(input_url);
        const remove_feeds = try storage.getFeedsWithUrl(arena.allocator(), input_url);
        try std.testing.expectEqual(@as(usize, 0), remove_feeds.len);
        const items = try storage.getFeedItemsWithFeedId(arena.allocator(), feed_id);
        try std.testing.expectEqual(@as(usize, 0), items.len);
        const updates = try storage.getFeedsToUpdate(arena.allocator(), input_url);
        try std.testing.expectEqual(@as(usize, 0), updates.len);
    }
}
