const std = @import("std");
const Uri = std.Uri;

pub const FeedInsert = struct {
    name: ?[]const u8 = null,
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
            .name = self.name,
            .feed_url = self.feed_url,
            .page_url = self.page_url,
            .updated_raw = self.updated_raw,
            .updated_timestamp = self.updated_timestamp,
        };
    }
};

pub const Feed = struct {
    feed_id: usize = 0,
    name: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,
};

pub const FeedRaw = struct {
    name: ?[]const u8 = null,
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
            .name = feed_raw.name,
            .feed_url = feed_raw.feed_url,
            .page_url = feed_raw.page_url,
            .updated_raw = feed_raw.updated_raw,
            .updated_timestamp = timestamp,
        };
    }
};
