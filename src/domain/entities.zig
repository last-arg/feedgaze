const std = @import("std");
const Uri = std.Uri;

pub const Feed = struct {
    feed_id: usize = 0,
    name: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,
};

pub const FeedItem = struct {
    item_id: usize = 0,
    feed_id: usize = 0,
    name: []const u8,
    id: ?[]const u8 = null,
    link: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,
};
