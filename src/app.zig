const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Storage = @import("./storage.zig").Storage;
const feed_types = @import("./feed_types.zig");
const FeedRaw = feed_types.FeedRaw;
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const FeedItemInsert = feed_types.FeedItemInsert;
const FeedItemRaw = feed_types.FeedItemRaw;
const print = std.debug.print;

const App = struct {
    const Self = @This();
    storage: Storage,

    const Error = error{
        FeedExists,
        NotFound,
    };

    pub fn init(allocator: Allocator) Self {
        return .{
            .storage = Storage.init(allocator),
        };
    }

    pub fn insertFeed(self: *Self, feed: Feed) !usize {
        var result = try feed.prepareAndValidate();
        result = self.storage.insertFeed(feed) catch |err| switch (err) {
            error.FeedExists => return Error.FeedExists,
            else => return error.Unknown,
        };

        return result.feed_id;
    }

    pub fn getFeed(self: Self, id: usize) ?Feed {
        return self.storage.getFeed(id);
    }

    pub fn deleteFeed(self: *Self, id: usize) !void {
        try self.storage.deleteFeed(id);
    }

    pub fn updateFeed(self: *Self, id: usize, data: FeedRaw) !void {
        const f = try data.toFeedInsert();
        f.validate() catch |err| switch (err) {
            else => error.Unknown,
        };
        const insert_id = self.storage.updateFeed(id, f) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return insert_id;
    }

    pub fn insertFeedItems(self: *Self, inserts: []FeedItem) ![]FeedItem {
        for (inserts) |*item| {
            // TODO: how to handle errors, invalid item?
            try item.prepareAndValidate();
        }
        const new_inserts = self.storage.insertFeedItems(inserts) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return new_inserts;
    }

    pub fn getFeedItem(self: *Self, id: usize) ?FeedItem {
        return self.storage.getFeedItem(id);
    }

    pub fn deleteFeedItems(self: *Self, ids: []usize) !void {
        try self.storage.deleteFeedItems(ids);
    }

    pub fn updateFeedItem(self: *Self, id: usize, data: FeedItemRaw) !void {
        const item = data.toFeedItemInsert();
        // item.validate() catch |err| switch (err) {
        //     else => error.Unknown,
        // };
        const insert_id = self.storage.updateFeedItem(id, item) catch |err| switch (err) {
            Storage.Error.NotFound => Error.NotFound,
            else => error.Unknown,
        };

        return insert_id;
    }

    pub fn deinit(self: *Self) void {
        defer self.storage.deinit();
    }
};

fn testFeed() Feed {
    return .{
        .name = "Feed title",
        .feed_url = "http://localhost/valid_url",
    };
}

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
        try std.testing.expectError(Feed.Error.InvalidUri, res);
    }

    {
        _ = try app.insertFeed(testFeed());
        try std.testing.expectEqual(app.storage.feeds.items.len, 1);

        const res = app.insertFeed(testFeed());
        try std.testing.expectError(App.Error.FeedExists, res);
    }
}

test "App.getFeed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.getFeed(1);
        try std.testing.expect(null == res);
    }

    {
        const id = try app.insertFeed(testFeed());
        const res = app.getFeed(id);
        try std.testing.expectEqual(id, res.?.feed_id);
    }
}

test "App.deleteFeed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.deleteFeed(1);
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const id = try app.insertFeed(testFeed());
        try app.deleteFeed(id);
        try std.testing.expectEqual(@as(usize, 0), app.storage.feeds.items.len);
    }
}

test "App.updateFeed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.updateFeed(1, testFeedRaw());
        try std.testing.expectError(error.NotFound, res);
    }

    {
        var feed = testFeed();
        const id = try app.insertFeed(feed);
        var raw = testFeedRaw();
        raw.name = "Updated title";
        try app.updateFeed(id, raw);
        try std.testing.expectEqualStrings(raw.name.?, app.storage.feeds.items[0].name.?);
    }
}

test "App.insertFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    var items = [_]FeedItem{
        .{ .feed_id = 1, .name = "Item title" },
    };
    {
        const res = app.insertFeedItems(&items);
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        items[0].feed_id = feed_id;
        const new_items = try app.insertFeedItems(&items);
        try std.testing.expectEqual(@as(usize, 1), new_items.len);
    }
}

test "App.getFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.getFeedItem(1);
        try std.testing.expect(null == res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .name = "Item title" }};
        const new_items = try app.insertFeedItems(&insert_items);
        const new_item_id = new_items[0].item_id.?;
        const item = app.getFeedItem(new_item_id);
        try std.testing.expectEqual(item.?.item_id, new_item_id);
        try std.testing.expectEqualStrings(item.?.name, insert_items[0].name);
    }
}

test "App.deleteFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        var ids = [_]usize{1};
        const res = app.deleteFeedItems(&ids);
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .name = "Item title" }};
        const new_items = try app.insertFeedItems(&insert_items);
        var ids = [_]usize{new_items[0].item_id.?};
        try app.deleteFeedItems(&ids);
        try std.testing.expectEqual(@as(usize, 0), app.storage.feed_items.items.len);
    }
}

test "App.updateFeedItem" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    {
        const res = app.updateFeedItem(1, .{ .feed_id = 1, .name = "Item title" });
        try std.testing.expectError(error.NotFound, res);
    }

    {
        const feed_id = try app.insertFeed(testFeed());
        var insert_items = [_]FeedItem{.{ .feed_id = feed_id, .name = "Item title" }};
        const new_items = try app.insertFeedItems(&insert_items);
        const item_id = new_items[0].item_id.?;
        const new_title = "Updated title";
        try app.updateFeedItem(item_id, .{ .feed_id = feed_id, .name = new_title });
        const item = app.getFeedItem(item_id);
        try std.testing.expectEqualStrings(new_title, item.?.name);
    }
}

test "add feed" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    // feedgaze add http://localhost:8282/atom.xml
    // - fetch url content
    // - content to feed (FeedRaw) and feed items ([]FeedItem)
    const raw = Feed{ .feed_url = "http://localhost/valid_url" };
    const feed_id = app.insertFeed(raw);
    const feed_items = [_]FeedItem{};
    for (feed_items) |*item| {
        item.feed_id = feed_id;
    }
    const new_items = try app.insertFeedItems(&feed_items);
    _ = new_items;
}

const FeedAndItems = struct {
    feed: Feed,
    items: []FeedItem,
};

// feed_id: usize = 0,
// name: ?[]const u8 = null,
// feed_url: []const u8,
// page_url: ?[]const u8 = null,
// updated_raw: ?[]const u8 = null,
// updated_timestamp: ?i64 = null,

const AtomParseState = enum {
    feed,
    entry,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

const AtomParseTag = enum {
    title,
    link,
    updated,
    id,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

const xml = @import("zig-xml");
pub fn parseAtom(allocator: Allocator, content: []const u8, url: []const u8) !void {
    var tmp_str = try std.BoundedArray(u8, 1024).init(0);
    var parser = xml.Parser.init(content);
    var feed = Feed{
        .feed_url = url,
    };
    var state: AtomParseState = .feed;
    var current_tag: ?AtomParseTag = null;
    var link_href: ?[]const u8 = null;
    var link_rel: []const u8 = "alternate";
    while (parser.next()) |event| {
        print("parent_tag: {?}\n", .{state});
        print("  current_tag: {?}\n", .{current_tag});
        switch (event) {
            .open_tag => |tag| {
                state = AtomParseState.fromString(tag) orelse .feed;
                current_tag = AtomParseTag.fromString(tag);
            },
            .close_tag => |tag| {
                const end_tag = AtomParseState.fromString(tag);
                if (end_tag != null and end_tag.? == .entry) {
                    state = .feed;
                }

                if (current_tag == null) {
                    continue;
                }

                if (state == .feed) {
                    switch (current_tag.?) {
                        .title => {
                            feed.name = try allocator.dupe(u8, tmp_str.slice());
                            tmp_str.resize(0) catch unreachable;
                        },
                        .link => {
                            if (link_href) |href| {
                                if (mem.eql(u8, "alternate", link_rel)) {
                                    feed.page_url = href;
                                } else if (mem.eql(u8, "self", link_rel)) {
                                    // TODO: do I want to change feed_url?
                                    // Already have it from fn args 'url'.
                                }
                            }
                            link_href = null;
                            link_rel = "alternate";
                        },
                        .id, .updated => {},
                    }
                }
                current_tag = null;
            },
            .attribute => |attr| {
                if (current_tag == null) {
                    continue;
                }
                switch (current_tag.?) {
                    .link => {
                        if (mem.eql(u8, "href", attr.name)) {
                            link_href = attr.raw_value;
                        } else if (mem.eql(u8, "rel", attr.name)) {
                            link_rel = attr.raw_value;
                        }
                    },
                    .title, .id, .updated => {},
                }
            },
            .comment => {},
            .processing_instruction => {},
            .character_data => |data| {
                print("character_data: |{s}|\n", .{data});
                if (current_tag == null) {
                    continue;
                }
                if (state == .feed) {
                    switch (current_tag.?) {
                        .title => {
                            const end = blk: {
                                const new_len = tmp_str.len + data.len;
                                if (new_len > tmp_str.capacity()) {
                                    break :blk new_len - tmp_str.capacity();
                                }
                                break :blk data.len;
                            };
                            if (end > 0) {
                                tmp_str.appendSliceAssumeCapacity(data[0..end]);
                            }
                        },
                        // <link /> is void element
                        .link => {},
                        // Can be site url. Don't need it because already
                        // have fallback url from fn arg 'url'.
                        .id => {},
                        .updated => feed.updated_raw = data,
                    }
                }
            },
        }
    }
    print("feed: {any}\n", .{feed});
    print("feed.name: {s}\n", .{feed.name.?});
}

test "parseAtom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = @embedFile("atom.atom");
    try parseAtom(arena.allocator(), content, "http://localhost/valid_url");
}
