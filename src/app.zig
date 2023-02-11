const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Storage = @import("./storage.zig").Storage;
const feed_types = @import("./feed_types.zig");
const FeedRaw = feed_types.FeedRaw;
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const FeedItemInsert = feed_types.FeedItemInsert;
const FeedItemRaw = feed_types.FeedItemRaw;
const print = std.debug.print;
const parse = @import("./app_parse.zig");
const FeedAndItems = parse.FeedAndItems;

const App = struct {
    const Self = @This();
    allocator: Allocator,
    storage: Storage,

    const Error = error{
        FeedExists,
        NotFound,
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

    pub fn deleteFeed(self: *Self, id: usize) !void {
        try self.storage.deleteFeed(id);
    }

    pub fn updateFeed(self: *Self, id: usize, data: FeedRaw) !void {
        const f = try data.toFeedInsert();
        f.validate() catch |err| switch (err) {
            else => error.Unknown,
        };
        const insert_id = self.storage.updateFeed(id, f) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return insert_id;
    }

    pub fn insertFeedItems(self: *Self, inserts: []FeedItem) ![]FeedItem {
        const new_inserts = self.storage.insertFeedItems(inserts) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return new_inserts;
    }

    pub fn getFeedItem(self: *Self, id: usize) ?FeedItem {
        return self.storage.getFeedItem(id);
    }

    pub fn deleteFeedItems(self: *Self, ids: []usize) !void {
        try self.storage.deleteFeedItems(ids);
    }

    pub fn updateFeedItem(self: *Self, id: usize, data: FeedItemRaw) !void {
        const item = data.toFeedItemInsert();
        // item.validate() catch |err| switch (err) {
        //     else => error.Unknown,
        // };
        const insert_id = self.storage.updateFeedItem(id, item) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return insert_id;
    }

    pub fn insertFeedAndItems(self: *Self, feed_and_items: *FeedAndItems, fallback_url: []const u8) !void {
        try feed_and_items.feed.prepareAndValidate(fallback_url);
        const feed_id = try self.insertFeed(feed_and_items.feed);
        try FeedItem.prepareAndValidateAll(feed_and_items.items, feed_id);
        _ = try self.insertFeedItems(feed_and_items.items);
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

fn testFeedRaw() FeedRaw {
    return .{
        .title = "Feed title",
        .feed_url = "http://localhost/valid_url",
    };
}

test "App.insertFeed" {
    std.testing.log_level = .debug;
    var app = try App.init(std.testing.allocator);
    defer app.deinit();

    {
        const test_feed = testFeed();
        const feed_id = try app.insertFeed(test_feed);
        const possible_id = try app.storage.getFeedByUrl(test_feed.feed_url);
        try std.testing.expectEqual(feed_id, possible_id.?);

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
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.deleteFeed(1);
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const id = try app.insertFeed(testFeed());
        try app.deleteFeed(id);
        try std.testing.expectEqual(@as(usize, 0), app.storage.feeds.items.len);
    }
}

test "App.updateFeed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.updateFeed(1, testFeedRaw());
        try std.testing.expectError(error.NotFound, res);
    }

    {
        var feed = testFeed();
        const id = try app.insertFeed(feed);
        var raw = testFeedRaw();
        raw.title = "Updated title";
        try app.updateFeed(id, raw);
        try std.testing.expectEqualStrings(raw.title.?, app.storage.feeds.items[0].title.?);
    }
}

// test "App.insertFeedItem" {
//     var app = App.init(std.testing.allocator);
//     defer app.deinit();

//     var items = [_]FeedItem{
//         .{ .feed_id = 1, .title = "Item title" },
//     };
//     {
//         const res = app.insertFeedItems(&items);
//         try std.testing.expectError(error.NotFound, res);
//     }

//     {
//         const feed_id = try app.insertFeed(testFeed());
//         items[0].feed_id = feed_id;
//         const new_items = try app.insertFeedItems(&items);
//         try std.testing.expectEqual(@as(usize, 1), new_items.len);
//     }
// }

test "App.getFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.getFeedItem(1);
        try std.testing.expect(null == res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .title = "Item title" }};
        const new_items = try app.insertFeedItems(&insert_items);
        const new_item_id = new_items[0].item_id.?;
        const item = app.getFeedItem(new_item_id);
        try std.testing.expectEqual(item.?.item_id, new_item_id);
        try std.testing.expectEqualStrings(item.?.title, insert_items[0].title);
    }
}

test "App.deleteFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        var ids = [_]usize{1};
        const res = app.deleteFeedItems(&ids);
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .title = "Item title" }};
        const new_items = try app.insertFeedItems(&insert_items);
        var ids = [_]usize{new_items[0].item_id.?};
        try app.deleteFeedItems(&ids);
        try std.testing.expectEqual(@as(usize, 0), app.storage.feed_items.items.len);
    }
}

test "App.updateFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.updateFeedItem(1, .{ .feed_id = 1, .title = "Item title" });
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .title = "Item title" }};
        const new_items = try app.insertFeedItems(&insert_items);
        const item_id = new_items[0].item_id.?;
        const new_title = "Updated title";
        try app.updateFeedItem(item_id, .{ .feed_id = feed_id, .title = new_title });
        const item = app.getFeedItem(item_id);
        try std.testing.expectEqualStrings(new_title, item.?.title);
    }
}

test "add feed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // feedgaze add http://localhost:8282/atom.xml
    // - fetch url content
    const input_url = "http://localhost/valid_url";
    const content = @embedFile("rss2.xml");
    var result = try parse.parse(arena.allocator(), content, .rss);
    try app.insertFeedAndItems(&result, input_url);
}
