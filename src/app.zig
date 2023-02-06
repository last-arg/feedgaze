const std = @import("std");
const Uri = std.Uri;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const FeedRaw = struct {
    name: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,

    const Error = error{
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

const App = struct {
    const Self = @This();
    storage: Storage,

    const Error = error{
        FeedExists,
    };

    pub fn init(allocator: Allocator) Self {
        return .{
            .storage = Storage.init(allocator),
        };
    }

    pub fn insertFeed(self: *Self, data: FeedRaw) !usize {
        const f = try data.toFeedInsert();
        f.validate() catch |err| switch (err) {
            else => error.Unknown,
        };
        const insert_id = self.storage.insertFeed(f) catch |err| switch (err) {
            error.FeedExists => Error.FeedExists,
            else => error.Unknown,
        };

        return insert_id;
    }

    pub fn deinit(self: *Self) void {
        defer self.storage.deinit();
    }
};

const Storage = struct {
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

fn testFeedRaw() FeedRaw {
    return .{
        .name = "Feed title",
        .feed_url = "http://localhost/valid_url",
    };
}

test "App.insertFeed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.insertFeed(.{ .feed_url = "<invalid_url>" });
        try std.testing.expectError(FeedRaw.Error.InvalidUri, res);
    }

    {
        _ = try app.insertFeed(testFeedRaw());
        try std.testing.expectEqual(app.storage.feeds.items.len, 1);

        const res = app.insertFeed(testFeedRaw());
        try std.testing.expectError(App.Error.FeedExists, res);
    }
}
