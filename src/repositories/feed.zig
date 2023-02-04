const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Feed = @import("../domain/entities.zig").Feed;
const Uri = std.Uri;

pub const InMemoryRepository = struct {
    const Self = @This();
    allocator: Allocator,
    feeds: ArrayList(Feed),

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .feeds = ArrayList(Feed).init(allocator),
        };
    }

    pub fn insert(self: *Self, feed: Feed) !usize {
        if (hasUrl(feed.feed_url, self.feeds.items)) {
            return error.FeedExists;
        }
        const index = self.feeds.items.len;
        try self.feeds.append(feed);
        return index;
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

    pub fn deinit(self: Self) void {
        self.feeds.deinit();
    }
};
