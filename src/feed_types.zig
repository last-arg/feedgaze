const std = @import("std");
const Uri = std.Uri;

pub const Feed = struct {
    const Self = @This();
    feed_id: usize = 0,
    title: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    pub const Error = error{
        InvalidUri,
    };

    pub fn prepareAndValidate(self: *Self, fallback_url: ?[]const u8) !void {
        if (self.feed_url.len == 0 and fallback_url == null) {
            return error.NoFeedUrl;
        }
        if (self.feed_url.len == 0) {
            self.feed_url = fallback_url.?;
        }
        _ = Uri.parse(self.feed_url) catch return Error.InvalidUri;
        var timestamp: ?i64 = null;
        if (self.updated_raw) |date| {
            // TODO: validate date string
            if (date.len > 0) {
                timestamp = @as(i64, 22);
            }
        }
    }
};

pub const FeedItem = struct {
    feed_id: usize = 0,
    item_id: ?usize = null,
    title: []const u8,
    id: ?[]const u8 = null,
    link: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    const Self = @This();

    pub fn prepareAndValidate(self: *Self, feed_id: usize) !void {
        self.feed_id = feed_id;
        // TODO: parse date
    }

    pub fn prepareAndValidateAll(items: []Self, feed_id: usize) !void {
        for (items) |*item| {
            try item.prepareAndValidate(feed_id);
        }
    }
};

pub const FeedUpdate = struct {
    feed_id: ?usize = null,
    cache_control_max_age: ?u32 = null,
    expires_utc: ?i64 = null,
    last_modified_utc: ?i64 = null,
    etag: ?[]const u8 = null,
};

pub const FeedToUpdate = struct {
    feed_id: usize,
    feed_url: []const u8,
};
