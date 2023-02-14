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

const App = struct {
    const Self = @This();
    allocator: Allocator,
    storage: Storage,

    const Error = error{
        FeedExists,
        FeedNotFound,
    };

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .storage = try Storage.init(allocator),
        };
    }

    pub fn insertFeed(self: *Self, feed: Feed) !usize {
        const result = self.storage.insertFeed(feed) catch |err| switch (err) {
            error.FeedExists => return Error.FeedExists,
            else => return error.Unknown,
        };

        return result;
    }

    pub fn getFeed(self: Self, id: usize) ?Feed {
        return self.storage.getFeed(id);
    }

    pub fn getFeedsWithUrl(self: *Self, allocator: Allocator, url: []const u8) ![]Feed {
        return self.storage.getFeedWithUrl(allocator, url);
    }

    pub fn getFeedsToUpdate(self: *Self, allocator: Allocator, url: []const u8) ![]FeedToUpdate {
        return self.storage.getFeedsToUpdate(allocator, url);
    }

    pub fn deleteFeed(self: *Self, id: usize) !void {
        try self.storage.deleteFeed(id);
    }

    pub fn updateFeed(self: *Self, feed: *Feed) !void {
        try feed.prepareAndValidate(null);
        return self.storage.updateFeed(feed.*) catch |err| switch (err) {
            Storage.Error.FeedNotFound => Error.FeedNotFound,
            else => error.Unknown,
        };
    }

    pub fn insertFeedItems(self: *Self, inserts: []FeedItem) ![]FeedItem {
        const new_inserts = self.storage.insertFeedItems(inserts) catch |err| switch (err) {
            Storage.Error.FeedNotFound => Error.FeedNotFound,
            else => error.Unknown,
        };

        return new_inserts;
    }

    pub fn getFeedItemsWithFeedId(self: *Self, allocator: Allocator, feed_id: usize) ![]FeedItem {
        return try self.storage.getFeedItemsWithFeedId(allocator, feed_id);
    }

    pub fn deleteFeedItems(self: *Self, ids: []usize) !void {
        try self.storage.deleteFeedItems(ids);
    }

    pub fn updateFeedItem(self: *Self, item: FeedItem) !void {
        try self.storage.updateFeedItem(item);
    }

    pub fn insertFeedAndItems(self: *Self, feed_and_items: *FeedAndItems, fallback_url: []const u8) !usize {
        try feed_and_items.feed.prepareAndValidate(fallback_url);
        const feed_id = try self.insertFeed(feed_and_items.feed);
        try FeedItem.prepareAndValidateAll(feed_and_items.items, feed_id);
        _ = try self.insertFeedItems(feed_and_items.items);
        return feed_id;
    }

    pub fn insertFeedUpdate(self: *Self, feed_update: FeedUpdate) !void {
        try self.storage.insertFeedUpdate(feed_update);
    }

    pub fn deinit(self: *Self) void {
        defer self.storage.deinit();
    }
};

fn testFeed() Feed {
    return .{
        .title = "Feed title",
        .feed_url = "http://localhost/valid_url",
    };
}

test "App.insertFeed" {
    std.testing.log_level = .debug;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = try App.init(arena.allocator());
    defer app.deinit();

    {
        const test_feed = testFeed();
        const feed_id = try app.insertFeed(test_feed);
        const feeds = try app.storage.getFeedsByUrl(arena.allocator(), test_feed.feed_url);
        try std.testing.expectEqual(feed_id, feeds[0].feed_id);

        const res = app.insertFeed(testFeed());
        try std.testing.expectError(App.Error.FeedExists, res);
    }
}

test "App.getFeed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.getFeed(1);
        try std.testing.expect(null == res);
    }

    {
        const id = try app.insertFeed(testFeed());
        const res = app.getFeed(id);
        try std.testing.expectEqual(id, res.?.feed_id);
    }
}

test "App.deleteFeed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    {
        var feed = testFeed();
        const id = try app.insertFeed(feed);
        try app.deleteFeed(id);
        const feeds = try app.storage.getFeedsByUrl(arena.allocator(), feed.feed_url);
        try std.testing.expectEqual(@as(usize, 0), feeds.len);
    }
}

test "App.updateFeed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    {
        var f = testFeed();
        f.feed_id = 1;
        const res = app.updateFeed(&f);
        try std.testing.expectError(error.FeedNotFound, res);
    }

    {
        var feed = testFeed();
        const id = try app.insertFeed(feed);
        feed.feed_id = id;
        feed.title = "Updated title";
        try app.updateFeed(&feed);
        const feeds = try app.storage.getFeedsByUrl(arena.allocator(), feed.feed_url);
        try std.testing.expectEqualStrings(feed.title.?, feeds[0].title.?);
    }
}

test "App.insertFeedItems" {
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    var items = [_]FeedItem{
        .{ .feed_id = 1, .title = "Item title" },
    };
    {
        const res = app.insertFeedItems(&items);
        try std.testing.expectError(error.FeedNotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        items[0].feed_id = feed_id;
        const new_items = try app.insertFeedItems(&items);
        try std.testing.expectEqual(@as(usize, 1), new_items.len);
    }
}

test "App.getFeedItemsByFeedId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    {
        const items = try app.getFeedItemsWithFeedId(arena.allocator(), 1);
        try std.testing.expectEqual(@as(usize, 0), items.len);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .title = "Item title" }};
        _ = try app.insertFeedItems(&insert_items);
        const items = try app.getFeedItemsWithFeedId(arena.allocator(), feed_id);
        try std.testing.expectEqual(@as(usize, 1), items.len);
        try std.testing.expectEqualStrings(insert_items[0].title, items[0].title);
    }
}

// test "App.deleteFeedItem" {
//     var app = App.init(std.testing.allocator);
//     defer app.deinit();

//     {
//         var ids = [_]usize{1};
//         const res = app.deleteFeedItems(&ids);
//         try std.testing.expectError(error.NotFound, res);
//     }

//     {
//         const feed_id = try app.insertFeed(testFeed());
//         var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .title = "Item title" }};
//         const new_items = try app.insertFeedItems(&insert_items);
//         var ids = [_]usize{new_items[0].item_id.?};
//         try app.deleteFeedItems(&ids);
//         try std.testing.expectEqual(@as(usize, 0), app.storage.feed_items.items.len);
//     }
// }

// test "App.updateFeedItem" {
//     var app = App.init(std.testing.allocator);
//     defer app.deinit();

//     {
//         const res = app.updateFeedItem(1, .{ .feed_id = 1, .title = "Item title" });
//         try std.testing.expectError(error.NotFound, res);
//     }

//     {
//         const feed_id = try app.insertFeed(testFeed());
//         var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .title = "Item title" }};
//         const new_items = try app.insertFeedItems(&insert_items);
//         const item_id = new_items[0].item_id.?;
//         const new_title = "Updated title";
//         try app.updateFeedItem(item_id, .{ .feed_id = feed_id, .title = new_title });
//         const item = app.getFeedItem(item_id);
//         try std.testing.expectEqualStrings(new_title, item.?.title);
//     }
// }

const Cli = struct {
    allocator: Allocator,
    storage: Storage,
    const Self = @This();

    const UpdateOptions = struct {
        search_term: ?[]const u8 = null,
        force: bool = false,
        all: bool = false,
    };

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
            const feed_update = FeedUpdate{ .feed_id = f_update.feed_id };
            const content = @embedFile("rss2.xml");
            const content_type = .rss;
            var parsed = try parse.parse(arena.allocator(), content, content_type);

            // feed url has changed, update feed
            if (!mem.eql(u8, f_update.feed_url, parsed.feed.feed_url)) {
                parsed.feed.feed_id = f_update.feed_id;
                try self.storage.updateFeed(parsed.feed);
            }

            // Update feed items
            try FeedItem.prepareAndValidateAll(parsed.items, f_update.feed_id);
            try self.storage.updateAndRemoveFeedItems(parsed.items);

            // Update feed_update
            try self.storage.updateFeedUpdate(feed_update);
        }
    }
};

test "all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    const input_url = "http://localhost/valid_url";
    var feed_id: usize = 0;
    {
        // Setup: add/insert feed and items
        // feedgaze add http://localhost:8282/rss2.xml

        // fetch url content
        const content = @embedFile("rss2.xml");

        // parse content
        var result = try parse.parse(arena.allocator(), content, .rss);
        try std.testing.expectEqual(@as(usize, 2), result.items.len);

        feed_id = try app.insertFeedAndItems(&result, input_url);
        const feed_id_null = app.insertFeedUpdate(.{});
        try std.testing.expectError(error.FeedIdNull, feed_id_null);
        try app.insertFeedUpdate(.{ .feed_id = feed_id });

        const feeds = try app.storage.getFeedsByUrl(arena.allocator(), input_url);
        try std.testing.expectEqual(feed_id, feeds[0].feed_id);
        const items = try app.storage.getFeedItemsWithFeedId(arena.allocator(), feed_id);
        try std.testing.expectEqual(result.items.len, items.len);
    }

    {
        // Update feed
        // feedgaze update <url> [--force]
        // - check if feed with <url> exists
        // - if not --force
        //   - see if feed needs updating
        // - update if needed
        var cli = Cli{ .allocator = arena.allocator(), .storage = app.storage };
        try cli.update(.{ .search_term = input_url });
        // const invalid_url = "<invalid_url>";
        // var updates = try app.getFeedsToUpdate(arena.allocator(), invalid_url);
        // try std.testing.expectEqual(@as(usize, 0), updates.len);
        // updates = try app.getFeedsToUpdate(arena.allocator(), input_url);
        // try std.testing.expectEqual(@as(usize, 1), updates.len);
        // try std.testing.expectEqualStrings(input_url, updates[0].feed_url);
    }

    {
        // Update item
        const items = try app.storage.getFeedItemsWithFeedId(arena.allocator(), feed_id);
        var item = items[0];
        var updated_title = "Updated title";
        item.title = updated_title;
        try app.updateFeedItem(item);
        const updated_items = try app.storage.getFeedItemsWithFeedId(arena.allocator(), feed_id);
        try std.testing.expectEqualStrings(updated_title, updated_items[0].title);
    }
}
