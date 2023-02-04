const std = @import("std");
const Uri = std.Uri;

pub const Feed = struct {
    name: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,
};
