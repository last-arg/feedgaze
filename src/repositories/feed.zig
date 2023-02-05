const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const entities = @import("../domain/entities.zig");
const Feed = entities.Feed;
const FeedItem = entities.FeedItem;
const Uri = std.Uri;
const assert = std.debug.assert;

pub const InMemoryRepository = struct {
    const Self = @This();
    allocator: Allocator,
    feeds: ArrayList(Feed),
    feed_id: usize = 0,
    feed_items: ArrayList(FeedItem),
    feed_item_id: usize = 0,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .feeds = ArrayList(Feed).init(allocator),
            .feed_items = ArrayList(FeedItem).init(allocator),
        };
    }

    pub fn insert(self: *Self, feed: Feed) !usize {
        if (hasUrl(feed.feed_url, self.feeds.items)) {
            return error.FeedExists;
        }
        const id = self.feed_id + 1;
        self.feed_id = id;
        var new_feed = feed;
        new_feed.feed_id = id;
        try self.feeds.append(new_feed);
        assert(id > 0);
        return id;
    }

    fn hasUrl(url: []const u8, feeds: []Feed) bool {
        for (feeds) |feed| {
            if (std.mem.eql(u8, url, feed.feed_url)) {
                return true;
            }
        }
        return false;
    }

    // Invalidates all feed indices after remove 'index'
    pub fn delete(self: *Self, url: []const u8) !void {
        const index = findFeed(url, self.feeds.items) orelse return error.NotFound;
        _ = self.feeds.swapRemove(index);
    }

    fn findFeed(url: []const u8, feeds: []Feed) ?usize {
        for (feeds) |feed, index| {
            if (std.mem.eql(u8, url, feed.feed_url)) {
                return index;
            }
        }
        return null;
    }

    fn findFeedById(id: usize, feeds: []Feed) ?usize {
        for (feeds) |feed, index| {
            if (id == feed.feed_id) {
                return index;
            }
        }
        return null;
    }

    pub fn update(self: *Self, feed: Feed) !void {
        assert(feed.feed_id > 0);
        const index = findFeedById(feed.feed_id, self.feeds.items) orelse return error.NotFound;
        self.feeds.items[index] = feed;
    }

    pub fn get(self: *Self, url: []const u8) !Feed {
        const index = findFeed(url, self.feeds.items) orelse return error.NotFound;
        return self.feeds.items[index];
    }

    pub fn insertItem(self: *Self, item: FeedItem) !usize {
        assert(item.feed_id > 0);
        if (!hasFeedWithId(item.feed_id, self.feeds.items)) {
            return error.FeedNotFound;
        }
        const id = self.feed_item_id + 1;
        var new_item = item;
        self.feed_item_id = id;
        new_item.item_id = id;
        try self.feed_items.append(new_item);
        assert(id > 0);
        return id;
    }

    fn hasFeedWithId(id: usize, feeds: []Feed) bool {
        for (feeds) |feed| {
            if (id == feed.feed_id) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: Self) void {
        self.feeds.deinit();
        self.feed_items.deinit();
    }
};
