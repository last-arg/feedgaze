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
    Conflict,
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
    }) catch return CreateError.Conflict;
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

test "return Conflict" {
    var repo = InMemoryRepository.init(std.testing.allocator);
    defer repo.deinit();
    const req = testRequest();
    _ = try repo.insert(.{ .feed_url = req.feed_url });

    const res = create(&repo, req);
    try std.testing.expectError(CreateError.Conflict, res);
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
