const std = @import("std");
const http = @import("http.zig");
const parse = @import("parse.zig");
const Feed = parse.Feed;
const zuri = @import("zuri");
const ArrayList = std.ArrayList;
const zfetch = @import("zfetch");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const fmt = std.fmt;
const assert = std.debug.assert;
const print = std.debug.print;
const log = std.log;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// Resource:
// https://github.com/kickscondor/fraidycat/blob/a0d38b0eef5eb3a6a463f58d17e76b02b0aea310/defs/social.json

// Install twitch-cli for generating access token and settig up mock-api env
// Install [twitch-cli](https://github.com/twitchdev/twitch-cli)

// Generate twitch access token
// $ twitch token
// Enter 'Client ID'
// Enter 'Client Secret'

// Setup twitch mock-api
// $ twitch start

// Input url
// https://twitch.tv/<login name>
// API request user
// https://api.twitch.tv/helix/users?login=<login name>
// get <id>
// API request videos
// <limit> - max 100
// https://api.twitch.tv/helix/videos?user_id=<id>&first=<limit>&type=archive
// Get necessary data

// const client_id = "i78kq9eeb08q8oxsrfc1iw734x84j7";
// const access_token = "Bearer lwq7tbx9a1ut24nz4rq8uvgpzk10q1";
// const base_url = "https://api.twitch.tv/helix";

const client_id = "6219780769d92ac44c8797d8b20739";
const access_token = "Bearer e11a98a862974be";
const base_url = "http://localhost:8181/mock";

const User = struct {
    id: []const u8,
    display_name: []const u8, // Will be feed title
};

pub fn getFeed(allocator: Allocator, url: []const u8) !Feed {
    const login_name = (try urlToLoginName(url)) orelse return error.NoUserNameInPath;

    try zfetch.init();
    defer zfetch.deinit(); // Does something on Windows systems. Doesn't allocate anything anyway

    var headers = zfetch.Headers.init(allocator);
    try headers.appendValue("Client-Id", client_id);
    try headers.appendValue("Authorization", access_token);

    const user = (try fetchUserByLogin(allocator, headers, login_name)) orelse return error.NoTwitchUser;
    const videos = try fetchFeedItems(allocator, headers, user);

    const feed = Feed{
        .title = user.display_name,
        .link = try fmt.allocPrint(allocator, "https://twitch.tv/{s}/videos", .{login_name}),
        .items = videos,
    };

    return feed;
}

test "getFeed()" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const login_name = "skateboarddrake390";
    // There are no videos with type archive in twitch-cli mock database
    const videos = try getFeed(allocator, "twitch.tv/" ++ login_name);
    _ = videos;
}

// Fetches archived user videos
pub fn fetchFeedItems(allocator: Allocator, headers: zfetch.Headers, user: User) ![]Feed.Item {
    const url = try fmt.allocPrint(allocator, "{s}/videos?type=archive&user_id={s}", .{ base_url, user.id });
    var req = try zfetch.Request.init(allocator, url, null);
    // Closing file socket + freeing allocations
    // defer req.deinit();
    // Only close the file, let AreanAllocator take care of freeing allocations
    defer req.socket.close();

    try req.do(.GET, headers, null);
    if (req.status.code == 200) {
        var is_content_type_json = false;
        for (req.headers.list.items) |h| {
            if (mem.eql(u8, h.name, "Content-Type") and mem.eql(u8, h.value, "application/json")) {
                is_content_type_json = true;
                break;
            }
        }
        if (!is_content_type_json) return error.InvalidContentType;

        const req_reader = req.reader();
        const body = try req_reader.readAllAlloc(allocator, std.math.maxInt(usize));

        var p = json.Parser.init(allocator, false);
        defer p.deinit();
        var tree = try p.parse(body);
        defer tree.deinit();

        var data = tree.root.Object.get("data").?;
        var items = try ArrayList(Feed.Item).initCapacity(allocator, data.Array.items.len);
        defer items.deinit();

        for (data.Array.items) |video| {
            const updated_raw = video.Object.get("created_at").?.String;
            const timestamp = try parse.Atom.parseDateToUtc(updated_raw);
            items.appendAssumeCapacity(.{
                .title = video.Object.get("title").?.String,
                .id = video.Object.get("id").?.String,
                .link = video.Object.get("url").?.String,
                .updated_raw = updated_raw,
                .updated_timestamp = @floatToInt(i64, timestamp.toSeconds()),
            });
        }
    } else {
        log.err("Twitch request to get {s} archive videos failed. Error: {d} {s}", .{ user.display_name, req.status.code, req.status.reason });
        return error.FetchingVideosFailed;
    }
    return &[_]Feed.Item{};
}

test "@active fetchFeedItems()" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try zfetch.init();
    defer zfetch.deinit(); // Does something on Windows systems. Doesn't allocate anything anyway

    var headers = zfetch.Headers.init(allocator);
    try headers.appendValue("Client-Id", client_id);
    try headers.appendValue("Authorization", access_token);

    const login_name = "skateboarddrake390";
    const user = try fetchUserByLogin(allocator, headers, login_name);
    std.debug.assert(user != null);
    // There are no videos with type archive in twitch-cli mock database
    _ = try fetchFeedItems(allocator, headers, user.?);
}

pub fn fetchUserByLogin(allocator: Allocator, headers: zfetch.Headers, login_name: []const u8) !?User {
    const url = try fmt.allocPrint(allocator, "{s}/users?login={s}", .{ base_url, login_name });
    var req = try zfetch.Request.init(allocator, url, null);
    // Closing file socket + freeing allocations
    // defer req.deinit();
    // Only close the file, let AreanAllocator take care of freeing allocations
    defer req.socket.close();

    try req.do(.GET, headers, null);
    if (req.status.code == 200) {
        var is_content_type_json = false;
        for (req.headers.list.items) |h| {
            if (mem.eql(u8, h.name, "Content-Type") and mem.eql(u8, h.value, "application/json")) {
                is_content_type_json = true;
                break;
            }
        }
        if (!is_content_type_json) return error.InvalidContentType;

        const req_reader = req.reader();
        const body = try req_reader.readAllAlloc(allocator, std.math.maxInt(usize));
        const Internal = struct { data: []User };
        var stream = std.json.TokenStream.init(body);
        const users = try std.json.parse(Internal, &stream, .{ .allocator = allocator, .ignore_unknown_fields = true });
        if (users.data.len > 0) return users.data[0];
    } else {
        log.err("Twitch API request for login name {s} failed. Error: {d} {s}", .{ login_name, req.status.code, req.status.reason });
        return error.FetchingUserFailed;
    }

    return null;
}

test "fetchUserByLogin()" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try zfetch.init();
    defer zfetch.deinit(); // Does something on Windows systems. Doesn't allocate anything anyway

    var headers = zfetch.Headers.init(allocator);
    try headers.appendValue("Client-Id", client_id);
    try headers.appendValue("Authorization", access_token);

    {
        const login_name = "jackjack4";
        const user = try fetchUserByLogin(allocator, headers, login_name);
        try expect(user != null);
    }

    {
        const user = try fetchUserByLogin(allocator, headers, "no_user");
        try expect(user == null);
    }
}

pub fn urlToLoginName(url: []const u8) !?[]const u8 {
    const uri = try zuri.Uri.parse(url, true);
    if (uri.path.len >= 1) {
        var login_name = uri.path[1..];
        const end_index = mem.indexOf(u8, login_name, "/") orelse login_name.len;
        return login_name[0..end_index];
    }
    return null;
}

test "urlToLoginName()" {
    const expected_login_name = "jackjack4";
    const domain = "twitch.tv";
    {
        const input_url = domain ++ "/" ++ expected_login_name;
        const login_name = try urlToLoginName(input_url);
        try expectEqualStrings(expected_login_name, login_name.?);
    }

    {
        const login_name = try urlToLoginName(domain);
        try expect(null == login_name);
    }
}
