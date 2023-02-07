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

const App = struct {
    const Self = @This();
    storage: Storage,

    const Error = error{
        FeedExists,
        NotFound,
    };

    pub fn init(allocator: Allocator) Self {
        return .{
            .storage = Storage.init(allocator),
        };
    }

    pub fn insertFeed(self: *Self, data: FeedRaw) !usize {
        const f = try data.toFeedInsert();
        f.validate() catch |err| switch (err) {
            else => error.Unknown,
        };
        const insert_id = self.storage.insertFeed(f) catch |err| switch (err) {
            error.FeedExists => Error.FeedExists,
            else => error.Unknown,
        };

        return insert_id;
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

    pub fn insertFeedItem(self: *Self, insert: FeedItemRaw) !usize {
        const f = insert.toFeedItemInsert();
        f.validate() catch |err| switch (err) {
            else => error.Unknown,
        };
        const insert_id = self.storage.insertFeedItem(f) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return insert_id;
    }

    pub fn getFeedItem(self: *Self, id: usize) ?FeedItem {
        return self.storage.getFeedItem(id);
    }

    pub fn deleteFeedItem(self: *Self, id: usize) !void {
        try self.storage.deleteFeedItem(id);
    }

    pub fn updateFeedItem(self: *Self, id: usize, data: FeedItemRaw) !void {
        const item = data.toFeedItemInsert();
        item.validate() catch |err| switch (err) {
            else => error.Unknown,
        };
        const insert_id = self.storage.updateFeedItem(id, item) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return insert_id;
    }

    pub fn deinit(self: *Self) void {
        defer self.storage.deinit();
    }
};

fn testFeedRaw() FeedRaw {
    return .{
        .name = "Feed title",
        .feed_url = "http://localhost/valid_url",
    };
}

test "App.insertFeed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.insertFeed(.{ .feed_url = "<invalid_url>" });
        try std.testing.expectError(FeedRaw.Error.InvalidUri, res);
    }

    {
        _ = try app.insertFeed(testFeedRaw());
        try std.testing.expectEqual(app.storage.feeds.items.len, 1);

        const res = app.insertFeed(testFeedRaw());
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
        const id = try app.insertFeed(testFeedRaw());
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
        const id = try app.insertFeed(testFeedRaw());
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
        var feed = testFeedRaw();
        const id = try app.insertFeed(feed);
        feed.name = "Updated title";
        try app.updateFeed(id, feed);
        try std.testing.expectEqual(feed.name, app.storage.feeds.items[0].name);
    }
}

test "App.insertFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.insertFeedItem(.{
            .feed_id = 1,
            .name = "Item title",
        });
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeedRaw());
        const item_id = try app.insertFeedItem(.{ .feed_id = feed_id, .name = "Item title" });
        try std.testing.expectEqual(@as(usize, 1), item_id);
    }
}

test "App.getFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.getFeedItem(1);
        try std.testing.expect(null == res);
    }

    {
        const feed_id = try app.insertFeed(testFeedRaw());
        const insert_item = .{ .feed_id = feed_id, .name = "Item title" };
        const item_id = try app.insertFeedItem(insert_item);
        const item = app.getFeedItem(item_id);
        try std.testing.expectEqual(item.?.item_id, item_id);
        try std.testing.expectEqualStrings(item.?.name, insert_item.name);
    }
}

test "App.deleteFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.deleteFeedItem(1);
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeedRaw());
        const item_id = try app.insertFeedItem(.{ .feed_id = feed_id, .name = "Item title" });
        try app.deleteFeedItem(item_id);
        try std.testing.expectEqual(@as(usize, 0), app.storage.feed_items.items.len);
        // try std.testing.expectEqualStrings(item.?.name, insert_item.name);
    }
}

test "App.updateFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.updateFeedItem(1, .{ .feed_id = 1, .name = "Item title" });
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeedRaw());
        const item_id = try app.insertFeedItem(.{ .feed_id = feed_id, .name = "Item title" });
        const new_title = "Updated title";
        try app.updateFeedItem(item_id, .{ .feed_id = feed_id, .name = new_title });
        const item = app.getFeedItem(item_id);
        try std.testing.expectEqualStrings(new_title, item.?.name);
    }
}
