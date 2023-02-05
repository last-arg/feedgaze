const std = @import("std");
const Uri = std.Uri;
const InMemoryRepository = @import("../repositories/feed.zig").InMemoryRepository;
const entities = @import("../domain/entities.zig");
const FeedItem = entities.FeedItem;

const CreateRequest = struct {
    feed_id: usize,
    // Atom: title (required)
    // Rss: title or description (requires one of these)
    name: []const u8,
    // Atom: id (required). Has to be URI.
    // Rss: guid (optional) or link (optional)
    id: ?[]const u8 = null,
    // In atom id (required) can also be link.
    // Check if id is link before outputting some data
    // Atom: link (optional),
    // Rss: link (optional)
    link: ?[]const u8 = null,
    // Atom: updated (required) or published (optional)
    // Rss: pubDate (optional)
    updated_raw: ?[]const u8 = null,
};

const CreateResponse = usize;

const CreateError = error{
    InvalidUri,
    FeedNotFound,
    Unknown,
};

pub fn create(repo: *InMemoryRepository, req: CreateRequest) !CreateResponse {
    if (req.link) |link| {
        _ = Uri.parse(link) catch return CreateError.InvalidUri;
    }
    var timestamp: ?i64 = blk: {
        if (req.updated_raw) |date| {
            // TODO: validate date string
            if (date.len > 0) {
                break :blk @as(i64, 22);
            }
        }
        break :blk null;
    };

    const insert_id = repo.insertItem(.{
        .feed_id = req.feed_id,
        .name = req.name,
        .id = req.id,
        .link = req.link,
        .updated_raw = req.updated_raw,
        .updated_timestamp = timestamp,
    }) catch |err| switch (err) {
        error.FeedNotFound => return CreateError.FeedNotFound,
        else => return CreateError.Unknown,
    };

    return insert_id;
}

test "create: FeedNotFound" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = create(&repo, .{ .feed_id = 1, .name = "Feed name" });
    try std.testing.expectError(CreateError.FeedNotFound, res);
}

test "create: success" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const feed_id = try repo.insert(.{ .feed_url = "http://localhost/valid_url", .name = "Feed name" });

    const res = try create(&repo, .{ .feed_id = feed_id, .name = "Item name" });
    try std.testing.expectEqual(@as(usize, 1), res);
}

const DeleteRequest = struct {
    item_id: usize,
};

const DeleteError = error{
    NotFound,
};

pub fn delete(repo: *InMemoryRepository, req: GetRequest) GetError!void {
    return repo.deleteItem(req.item_id) catch |err| switch (err) {
        error.NotFound => GetError.NotFound,
    };
}

test "delete: NotFound" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = delete(&repo, .{ .item_id = 1 });
    try std.testing.expectError(GetError.NotFound, res);
}

test "delete: success" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const url = "http://localhost/valid_url";
    const feed_id = try repo.insert(.{ .feed_url = url });
    const item_id = try repo.insertItem(.{ .feed_id = feed_id, .name = "Item name" });
    try delete(&repo, .{ .item_id = item_id });
}

const GetRequest = struct {
    item_id: usize,
};

const GetError = error{
    NotFound,
};

pub fn get(repo: *InMemoryRepository, req: GetRequest) GetError!FeedItem {
    return repo.getItem(req.item_id) catch |err| switch (err) {
        error.NotFound => GetError.NotFound,
    };
}

test "get: NotFound" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = get(&repo, .{ .item_id = 1 });
    try std.testing.expectError(GetError.NotFound, res);
}

test "get: success" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const url = "http://localhost/valid_url";
    const feed_id = try repo.insert(.{ .feed_url = url });
    var item = FeedItem{ .feed_id = feed_id, .name = "Item name" };
    item.item_id = try repo.insertItem(item);
    const res = try get(&repo, .{ .item_id = item.item_id });
    try std.testing.expectEqual(item, res);
}
