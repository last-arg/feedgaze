const std = @import("std");
const Uri = std.Uri;
const print = std.debug.print;
const InMemoryRepository = @import("../repositories/feed.zig").InMemoryRepository;
const entities = @import("../domain/entities.zig");
const Feed = entities.Feed;

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

const UpdateRequest = CreateRequest;

const UpdateError = error{
    InvalidUri,
    NotFound,
};

pub fn update(repo: *InMemoryRepository, req: UpdateRequest) UpdateError!void {
    _ = Uri.parse(req.feed_url) catch return UpdateError.InvalidUri;
    var timestamp: ?i64 = null;
    if (req.updated_raw) |date| {
        // TODO: validate date string
        if (date.len > 0) {
            timestamp = @as(i64, 22);
        }
    }
    return repo.update(.{
        .name = req.name,
        .feed_url = req.feed_url,
        .page_url = req.page_url,
        .updated_raw = req.updated_raw,
        .updated_timestamp = timestamp,
    }) catch |err| switch (err) {
        error.NotFound => UpdateError.NotFound,
    };
}

test "update: InvalidUri" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = update(&repo, .{ .feed_url = "<invalid_url>" });
    try std.testing.expectError(UpdateError.InvalidUri, res);
}

test "update: NotFound" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = update(&repo, .{ .feed_url = "http://localhost/valid_url" });
    try std.testing.expectError(UpdateError.NotFound, res);
}

test "update: success" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    var req = testRequest();
    _ = try repo.insert(.{ .feed_url = req.feed_url });

    const name = "New title";
    try update(&repo, .{ .feed_url = req.feed_url, .name = name });
    try std.testing.expectEqualStrings(name, repo.feeds.items[0].name.?);
}

const GetRequest = struct {
    feed_url: []const u8,
};

const GetRespond = Feed;

const GetError = error{
    InvalidUri,
    NotFound,
};

pub fn get(repo: *InMemoryRepository, req: GetRequest) GetError!GetRespond {
    _ = Uri.parse(req.feed_url) catch return GetError.InvalidUri;
    return repo.get(req.feed_url) catch |err| switch (err) {
        error.NotFound => GetError.NotFound,
    };
}

test "get: InvalidUri" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = get(&repo, .{ .feed_url = "<invalid_url>" });
    try std.testing.expectError(GetError.InvalidUri, res);
}

test "get: NotFound" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();

    const res = get(&repo, .{ .feed_url = "http://localhost/valid_url" });
    try std.testing.expectError(GetError.NotFound, res);
}

test "get: success" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const req = testRequest();
    const feed = Feed{ .feed_url = req.feed_url, .name = req.name };
    _ = try repo.insert(feed);

    const res = try get(&repo, .{ .feed_url = req.feed_url });
    try std.testing.expectEqual(feed, res);
}
