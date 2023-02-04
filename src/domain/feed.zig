const std = @import("std");
const Uri = std.Uri;
const print = std.debug.print;
const InMemoryRepository = @import("../repositories/feed.zig").InMemoryRepository;
// business logic
// https://alexis-lozano.com/hexagonal-architecture-in-rust-1/

const CreateRequest = struct {
    name: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
};

const CreateResponse = usize;

const CreateError = error{
    InvalidUri,
    FeedExists,
    Unknown,
};

pub fn create(repo: *InMemoryRepository, req: CreateRequest) CreateError!CreateResponse {
    _ = Uri.parse(req.feed_url) catch return CreateError.InvalidUri;
    var timestamp: ?i64 = null;
    if (req.updated_raw) |date| {
        // TODO: validate date string
        if (date.len > 0) {
            timestamp = @as(i64, 22);
        }
    }
    const insert_id = repo.insert(.{
        .name = req.name,
        .feed_url = req.feed_url,
        .page_url = req.page_url,
        .updated_raw = req.updated_raw,
        .updated_timestamp = timestamp,
    }) catch |err| return switch (err) {
        error.FeedExists => CreateError.FeedExists,
        else => CreateError.Unknown,
    };
    return insert_id;
}

fn testRequest() CreateRequest {
    return CreateRequest{
        .name = "Valid Feed",
        .feed_url = "http://localhost/valid_url",
    };
}

fn testRequestInvalid() CreateRequest {
    return CreateRequest{
        .name = "Invalid Feed",
        .feed_url = "<invalid_url>",
    };
}

test "return FeedExists" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const req = testRequest();
    _ = try repo.insert(.{ .feed_url = req.feed_url });

    const res = create(&repo, req);
    try std.testing.expectError(CreateError.FeedExists, res);
}

test "return InvalidUri" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const req = testRequestInvalid();

    const res = create(&repo, req);
    try std.testing.expectError(CreateError.InvalidUri, res);
}

test "return Response" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const req = testRequest();

    const res = try create(&repo, req);
    try std.testing.expectEqual(@as(usize, 0), res);
}

const DeleteRequest = struct {
    feed_url: []const u8,
};

const DeleteError = error{
    InvalidUri,
    NotFound,
};

pub fn delete(repo: *InMemoryRepository, req: DeleteRequest) DeleteError!void {
    _ = Uri.parse(req.feed_url) catch return CreateError.InvalidUri;
    return repo.delete(req.feed_url) catch |err| switch (err) {
        error.NotFound => DeleteError.NotFound,
    };
}

test "delete: InvalidUri" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = delete(&repo, .{ .feed_url = "<invalid_url>" });
    try std.testing.expectError(DeleteError.InvalidUri, res);
}

test "delete: NotFound" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = delete(&repo, .{ .feed_url = "http://localhost/valid_url" });
    try std.testing.expectError(DeleteError.NotFound, res);
}

test "delete: success" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const req = testRequest();
    _ = try repo.insert(.{ .feed_url = req.feed_url });

    try delete(&repo, .{ .feed_url = req.feed_url });
}
