const std = @import("std");
const Uri = std.Uri;
const InMemoryRepository = @import("../repositories/feed.zig").InMemoryRepository;

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
