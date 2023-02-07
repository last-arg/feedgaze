const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedInsert = feed_types.FeedInsert;
const FeedItem = feed_types.FeedItem;
const FeedItemInsert = feed_types.FeedItemInsert;

pub const Storage = struct {
    const Self = @This();
    allocator: Allocator,
    feeds: ArrayList(Feed),
    feed_id: usize = 0,
    feed_items: ArrayList(FeedItem),
    feed_item_id: usize = 0,

    pub const Error = error{
        NotFound,
        FeedExists,
    };

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .feeds = ArrayList(Feed).init(allocator),
            .feed_items = ArrayList(FeedItem).init(allocator),
        };
    }

    pub fn insertFeed(self: *Self, feed_insert: FeedInsert) !usize {
        if (hasUrl(feed_insert.feed_url, self.feeds.items)) {
            return Error.FeedExists;
        }
        const id = self.feed_id + 1;
        const feed = feed_insert.toFeed(id);
        try self.feeds.append(feed);
        assert(id > 0);
        self.feed_id = id;
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

    pub fn getFeed(self: Self, id: usize) ?Feed {
        const index = findFeedIndex(id, self.feeds.items) orelse return null;
        return self.feeds.items[index];
    }

    fn findFeedIndex(id: usize, feeds: []Feed) ?usize {
        for (feeds) |f, i| {
            if (id == f.feed_id) {
                return i;
            }
        }
        return null;
    }

    pub fn deleteFeed(self: *Self, id: usize) !void {
        const index = findFeedIndex(id, self.feeds.items) orelse return Error.NotFound;
        _ = self.feeds.swapRemove(index);
    }

    pub fn updateFeed(self: *Self, id: usize, feed_insert: FeedInsert) !void {
        assert(id > 0);
        const index = findFeedIndex(id, self.feeds.items) orelse return Error.NotFound;
        self.feeds.items[index] = feed_insert.toFeed(id);
    }

    pub fn deinit(self: *Self) void {
        self.feeds.deinit();
        self.feed_items.deinit();
    }

    pub fn insertFeedItems(self: *Self, inserts: []FeedItem) ![]FeedItem {
        for (inserts) |*item| {
            if (!hasFeedWithId(item.feed_id, self.feeds.items)) {
                return Error.NotFound;
            }
            const id = self.feed_item_id + 1;
            item.item_id = id;
            try self.feed_items.append(item.*);
            assert(id > 0);
            self.feed_item_id = id;
        }
        return inserts;
    }

    fn hasFeedWithId(id: usize, feeds: []Feed) bool {
        for (feeds) |feed| {
            if (id == feed.feed_id) {
                return true;
            }
        }
        return false;
    }

    pub fn getFeedItem(self: Self, id: usize) ?FeedItem {
        const index = findFeedItemIndex(id, self.feed_items.items) orelse return null;
        return self.feed_items.items[index];
    }

    fn findFeedItemIndex(id: usize, items: []FeedItem) ?usize {
        for (items) |item, i| {
            if (id == item.feed_id) {
                return i;
            }
        }
        return null;
    }

    pub fn deleteFeedItems(self: *Self, ids: []usize) !void {
        for (ids) |id| {
            const index = findFeedItemIndex(id, self.feed_items.items) orelse return Error.NotFound;
            _ = self.feed_items.swapRemove(index);
        }
    }

    pub fn updateFeedItem(self: *Self, id: usize, item_insert: FeedItemInsert) !void {
        assert(id > 0);
        const index = findFeedItemIndex(id, self.feed_items.items) orelse return Error.NotFound;
        self.feed_items.items[index] = item_insert.toFeedItem(id);
    }
};
