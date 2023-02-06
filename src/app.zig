const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Storage = @import("./storage.zig").Storage;
const feed_types = @import("./feed_types.zig");
const FeedRaw = feed_types.FeedRaw;

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
