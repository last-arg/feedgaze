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
            return error.Conflict;
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

    pub fn deinit(self: Self) void {
        self.feeds.deinit();
    }
};
