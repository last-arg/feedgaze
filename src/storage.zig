const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedInsert = feed_types.FeedInsert;

pub const Storage = struct {
    const Self = @This();
    allocator: Allocator,
    feeds: ArrayList(Feed),
    feed_id: usize = 0,

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .feeds = ArrayList(Feed).init(allocator),
        };
    }

    pub fn insertFeed(self: *Self, feed_insert: FeedInsert) !usize {
        if (hasUrl(feed_insert.feed_url, self.feeds.items)) {
            return error.FeedExists;
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

    pub fn deinit(self: *Self) void {
        self.feeds.deinit();
    }
};
