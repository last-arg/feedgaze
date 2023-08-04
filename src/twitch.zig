const std = @import("std");
const http = @import("http.zig");
const parse = @import("parse.zig");
const Feed = parse.Feed;
const zuri = @import("zuri");
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
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
const curl = @import("curl_extend.zig");

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

const client_id = "15abb4936487b0d256e47253445f35";
const access_token = "Bearer f3aecd0d35279ac";
const base_url = "http://localhost:8181/mock";

var twitch_headers = http.base_headers ++ [_][]const u8{
    fmt.comptimePrint("Client-Id: {s}", .{client_id}),
    fmt.comptimePrint("Authorization: {s}", .{access_token}),
};

const User = struct {
    id: []const u8,
    display_name: []const u8, // Will be feed title
};

pub fn getFeed(arena: *ArenaAllocator, url: []const u8) !Feed {
    const login_name = (try urlToLoginName(url)) orelse return error.NoUserNameInPath;
    const user = (try fetchUserByLogin(arena, &twitch_headers, login_name)) orelse return error.NoTwitchUser;
    const videos = try fetchFeedItems(arena, &twitch_headers, user);

    const feed = Feed{
        .title = user.display_name,
        .link = try fmt.allocPrint(arena.allocator(), "https://twitch.tv/{s}/videos", .{login_name}),
        .items = videos,
    };

    return feed;
}

test "getFeed()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try curl.globalInit();
    defer curl.globalCleanup();

    const login_name = "skateboarddrake390";
    // There are no videos with type archive in twitch-cli mock database
    const videos = try getFeed(&arena, "twitch.tv/" ++ login_name);
    _ = videos;
}

// Fetches archived user videos
pub fn fetchFeedItems(arena: *ArenaAllocator, headers: [][]const u8, user: User) ![]Feed.Item {
    const url = try fmt.allocPrint(arena.allocator(), "{s}/videos?type=archive&user_id={s}", .{ base_url, user.id });
    var resp = try http.resolveRequestCurl(arena, url, .{ .headers = headers });

    if (resp.status_code == 200) {
        const is_content_type_json = blk: {
            var last_header = curl.getLastHeader(resp.headers_fifo.readableSlice(0));
            if (curl.getHeaderValue(last_header, "content-type:")) |value| {
                break :blk std.ascii.indexOfIgnoreCase(value, "application/json") != null;
            }
            break :blk false;
        };
        if (!is_content_type_json) return error.InvalidContentType;

        const body = resp.body_fifo.readableSlice(0);
        var p = json.Parser.init(arena.allocator(), false);
        defer p.deinit();
        var tree = try p.parse(body);
        defer tree.deinit();

        var data = tree.root.Object.get("data").?;
        var items = try ArrayList(Feed.Item).initCapacity(arena.allocator(), data.Array.items.len);
        defer items.deinit();

        for (data.Array.items) |video| {
            const updated_raw = video.Object.get("created_at").?.String;
            const timestamp = try parse.Atom.parseDateToUtc(updated_raw);
            items.appendAssumeCapacity(.{
                .title = video.Object.get("title").?.String,
                .id = video.Object.get("id").?.String,
                .link = video.Object.get("url").?.String,
                .updated_raw = updated_raw,
                .updated_timestamp = @as(i64, @intFromFloat(timestamp.toSeconds())),
            });
        }
    } else {
        log.err("Twitch request to get {s} archive videos failed. HTTP status code: {d}", .{ user.display_name, resp.status_code });
        return error.FetchingVideosFailed;
    }
    return &[_]Feed.Item{};
}

test "fetchFeedItems()" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    try curl.globalInit();
    defer curl.globalCleanup();

    const login_name = "skateboarddrake390";
    const user = try fetchUserByLogin(&arena, &twitch_headers, login_name);
    std.debug.assert(user != null);
    // There are no videos with type archive in twitch-cli mock database
    _ = try fetchFeedItems(&arena, &twitch_headers, user.?);
}

pub fn fetchUserByLogin(arena: *ArenaAllocator, headers: [][]const u8, login_name: []const u8) !?User {
    const url = try fmt.allocPrint(arena.allocator(), "{s}/users?login={s}", .{ base_url, login_name });
    var resp = try http.resolveRequestCurl(arena, url, .{ .headers = headers });

    if (resp.status_code == 200) {
        const is_content_type_json = blk: {
            var last_header = curl.getLastHeader(resp.headers_fifo.readableSlice(0));
            if (curl.getHeaderValue(last_header, "content-type:")) |value| {
                break :blk std.ascii.indexOfIgnoreCase(value, "application/json") != null;
            }
            break :blk false;
        };
        if (!is_content_type_json) return error.InvalidContentType;

        const body = resp.body_fifo.readableSlice(0);
        const Internal = struct { data: []User };
        var stream = std.json.TokenStream.init(body);
        const users = try std.json.parse(Internal, &stream, .{ .allocator = arena.allocator(), .ignore_unknown_fields = true });
        if (users.data.len > 0) return users.data[0];
    } else {
        log.err("Twitch API request for login name '{s}' failed. HTTP status code: {d}", .{ login_name, resp.status_code });
        return error.FetchingUserFailed;
    }

    return null;
}

test "fetchUserByLogin()" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    try curl.globalInit();
    defer curl.globalCleanup();

    {
        const login_name = "jackjack4";
        const user = try fetchUserByLogin(&arena, &twitch_headers, login_name);
        try expect(user != null);
    }

    {
        const user = try fetchUserByLogin(&arena, &twitch_headers, "no_user");
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
