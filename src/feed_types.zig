const std = @import("std");
const Uri = std.Uri;

pub const FeedInsert = struct {
    title: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    pub fn validate(self: @This()) !void {
        _ = self;
    }

    pub fn toFeed(self: @This(), id: usize) Feed {
        return .{
            .feed_id = id,
            .title = self.title,
            .feed_url = self.feed_url,
            .page_url = self.page_url,
            .updated_raw = self.updated_raw,
            .updated_timestamp = self.updated_timestamp,
        };
    }
};

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

    pub fn prepareAndValidate(self: Self) !Self {
        _ = Uri.parse(self.feed_url) catch return Error.InvalidUri;
        var timestamp: ?i64 = null;
        if (self.updated_raw) |date| {
            // TODO: validate date string
            if (date.len > 0) {
                timestamp = @as(i64, 22);
            }
        }

        return self;
    }
};

pub const FeedRaw = struct {
    title: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,

    pub const Error = error{
        InvalidUri,
    };

    pub fn toFeedInsert(feed_raw: FeedRaw) !FeedInsert {
        _ = Uri.parse(feed_raw.feed_url) catch return Error.InvalidUri;
        var timestamp: ?i64 = null;
        if (feed_raw.updated_raw) |date| {
            // TODO: validate date string
            if (date.len > 0) {
                timestamp = @as(i64, 22);
            }
        }
        return .{
            .title = feed_raw.title,
            .feed_url = feed_raw.feed_url,
            .page_url = feed_raw.page_url,
            .updated_raw = feed_raw.updated_raw,
            .updated_timestamp = timestamp,
        };
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

    pub fn prepareAndValidate(self: *@This()) !void {
        _ = self;
    }
};

pub const FeedItemInsert = struct {
    feed_id: usize,
    title: []const u8,
    id: ?[]const u8 = null,
    link: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    pub fn toFeedItem(raw: FeedItemInsert, id: usize) FeedItem {
        return .{
            .feed_id = raw.feed_id,
            .item_id = id,
            .title = raw.title,
            .id = raw.id,
            .link = raw.link,
            .updated_raw = raw.updated_raw,
            .updated_timestamp = raw.updated_timestamp,
        };
    }
};

pub const FeedItemRaw = struct {
    feed_id: usize,
    title: []const u8,
    id: ?[]const u8 = null,
    link: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,

    pub fn toFeedItemInsert(raw: FeedItemRaw) FeedItemInsert {
        var timestamp: ?i64 = null;
        if (raw.updated_raw) |date| {
            // TODO: validate date string
            if (date.len > 0) {
                timestamp = @as(i64, 22);
            }
        }
        return .{
            .feed_id = raw.feed_id,
            .title = raw.title,
            .id = raw.id,
            .link = raw.link,
            .updated_raw = raw.updated_raw,
            .updated_timestamp = timestamp,
        };
    }
};
