const std = @import("std");
const datetime = @import("zig-datetime").datetime;
const feed_types = @import("./feed_types.zig");
const ContentType = feed_types.ContentType;
const RssDateTime = feed_types.RssDateTime;
const FetchOptions = feed_types.FetchOptions;
const http = std.http;
const mem = std.mem;
const print = std.debug.print;
const Client = http.Client;
const Allocator = mem.Allocator;
const Request = http.Client.Request;
const Response = http.Client.Response;
const Uri = std.Uri;
const assert = std.debug.assert;

pub const HeaderValues = struct {
    content_type: ?ContentType = null,
    etag: ?[]const u8 = null,
    last_modified: ?i64 = null,
    expires: ?i64 = null,
    max_age: ?u32 = null,

    pub fn fromRawHeader(input: []const u8) HeaderValues {
        const etag_key = "etag:";
        const content_type_key = "content-type:";
        const last_modified_key = "last-modified:";
        const expires_key = "expires:";
        const cache_control_key = "cache-control:";

        var result: HeaderValues = .{};
        var iter = std.mem.split(u8, input, "\r\n");
        _ = iter.first();
        while (iter.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, etag_key)) {
                result.etag = std.mem.trim(u8, line[etag_key.len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, content_type_key)) {
                result.content_type = ContentType.fromString(std.mem.trim(u8, line[content_type_key.len..], " "));
            } else if (std.ascii.startsWithIgnoreCase(line, last_modified_key)) {
                const raw = std.mem.trim(u8, line[last_modified_key.len..], " ");
                result.last_modified = RssDateTime.parse(raw) catch null;
            } else if (std.ascii.startsWithIgnoreCase(line, expires_key)) {
                const raw = std.mem.trim(u8, line[expires_key.len..], " ");
                result.expires = RssDateTime.parse(raw) catch null;
            } else if (std.ascii.startsWithIgnoreCase(line, cache_control_key)) {
                var key_value_iter = std.mem.split(u8, line[cache_control_key.len..], ",");
                while (key_value_iter.next()) |key_value| {
                    var pair_iter = mem.split(u8, key_value, "=");
                    const key = pair_iter.next() orelse continue;
                    const value = pair_iter.next() orelse continue;
                    if (mem.eql(u8, "max-age", key)) {
                        result.max_age = std.fmt.parseUnsigned(u32, value, 10) catch continue;
                        break;
                    } else if (mem.eql(u8, "s-maxage", value)) {
                        result.max_age = std.fmt.parseUnsigned(u32, value, 10) catch continue;
                    }
                }
            }
        }
        return result;
    }
};

// Resources:
// https://jackevansevo.github.io/the-struggles-of-building-a-feed-reader.html
// https://kevincox.ca/2022/05/06/rss-feed-best-practices/

// Can start with:
// '<a '
// '<link '
// Example: '<link rel="alternate" type="application/rss+xml" title="Example" href="/rss.xml">'

// Possible file ends:
// '.rss'
// '.atom'
// '.xml'

// Common feed link patterns
// '/rss.xml'
// '/index.xml'
// '/atom.xml'
// '/feed.xml'
// '/feed'
// '/rss'
fn parseHtmlForFeedLinks(input: []const u8, feed_arr: *FeedLinkArray) !void {
    // print("|{s}|\n", .{input});
    var content = input;
    while (std.mem.indexOfScalar(u8, content, '<')) |start_index| {
        content = content[start_index + 1 ..];
        const is_a = std.ascii.startsWithIgnoreCase(content, "a ");
        const is_link = std.ascii.startsWithIgnoreCase(content, "link ");
        if (!is_a and !is_link) {
            if (std.mem.startsWith(u8, content, "!--")) {
                // Is a comment. Skip comment.
                content = content[4..];
                if (std.mem.indexOf(u8, content, "-->")) |end| {
                    print("comment\n", .{});
                    content = content[end + 1 ..];
                }
            }
            continue;
        }
        var end_index = std.mem.indexOfScalar(u8, content, '>') orelse return;
        if (is_link and content[end_index - 1] == '/') {
            end_index -= 1;
        }
        const new_start: usize = if (is_a) 2 else 5;
        var attrs_raw = content[new_start..end_index];
        content = content[end_index..];

        var rel: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var link: ?[]const u8 = null;
        var link_type: ?[]const u8 = null;

        while (mem.indexOfScalar(u8, attrs_raw, '=')) |eql_index| {
            const name = std.mem.trimLeft(u8, attrs_raw[0..eql_index], " ");
            attrs_raw = attrs_raw[eql_index + 1 ..];
            var sep: u8 = ' ';
            const first = attrs_raw[0];
            if (first == '\'' or first == '"') {
                sep = first;
                attrs_raw = attrs_raw[1..];
            }
            const attr_end = mem.indexOfScalar(u8, attrs_raw, sep) orelse attrs_raw.len;
            const value = attrs_raw[0..attr_end];
            if (attr_end != attrs_raw.len) {
                attrs_raw = attrs_raw[attr_end + 1 ..];
            }

            if (std.ascii.eqlIgnoreCase(name, "type")) {
                link_type = value;
            } else if (std.ascii.eqlIgnoreCase(name, "rel")) {
                rel = value;
            } else if (std.ascii.eqlIgnoreCase(name, "href")) {
                link = value;
            } else if (std.ascii.eqlIgnoreCase(name, "title")) {
                title = value;
            }
        }

        if (rel != null and link != null and link_type != null and
            std.ascii.eqlIgnoreCase(rel.?, "alternate"))
        {
            if (FeedLink.Type.fromString(link_type.?)) |valid_type| {
                const allocator = feed_arr.allocator;
                try feed_arr.append(.{
                    .title = if (title) |t| try allocator.dupe(u8, t) else null,
                    .link = try allocator.dupe(u8, link.?),
                    .type = valid_type,
                });
            }
        }
    }
}

const FeedLink = struct {
    link: []const u8,
    type: ContentType,
    title: ?[]const u8 = null,
};

const FeedLinkArray = std.ArrayList(FeedLink);

pub const FeedRequest = struct {
    request: Request,
    const Self = @This();

    pub fn init(client: *Client, url: Uri, opts: FetchOptions) !Self {
        var bounded = try std.BoundedArray(http.CustomHeader, 3).init(1);
        bounded.buffer[0] = .{
            .name = "Accept",
            .value = "application/atom+xml, application/rss+xml, text/xml, application/xml, text/html",
        };
        if (opts.etag) |etag| {
            bounded.appendAssumeCapacity(.{ .name = "If-Match", .value = etag });
        }
        var date_buf: [29]u8 = undefined;
        if (opts.last_modified_utc) |utc| {
            const date_slice = try datetime.Datetime.formatHttpFromTimestamp(&date_buf, utc);
            bounded.appendAssumeCapacity(.{ .name = "If-Modified-Since", .value = date_slice });
        }

        const headers = Request.Headers{
            // .version = .@"HTTP/1.0",
            // .connection = .close,
            .user_agent = "feedgaze",
            .custom = bounded.slice(),
        };

        var req = try client.request(url, headers, .{});
        // try req.start();
        try req.do();
        print("header: |{s}|\n", .{req.response.parser.header_bytes.items});
        return .{ .request = req };
    }

    pub fn getBody(self: *Self, allocator: Allocator) ![]const u8 {
        return try self.request.reader().readAllAlloc(allocator, std.math.maxInt(u32));
    }

    pub fn getHeaderRaw(self: Self) []const u8 {
        return self.request.response.parser.header_bytes.items;
    }

    pub fn deinit(self: *Self) void {
        self.request.deinit();
    }
};

pub const TestRequest = struct {
    const Self = @This();
    body: []const u8 = "self.body",
    pub var text: []const u8 = "TestRequest.text";

    pub fn init(client: *Client, url: Uri, opts: FetchOptions) !Self {
        _ = client;
        _ = url;
        _ = opts;
        return .{};
    }

    pub fn getBody(self: *Self, allocator: Allocator) ![]const u8 {
        _ = self;
        _ = allocator;
        return TestRequest.text;
    }

    pub fn getHeaderRaw(self: Self) []const u8 {
        _ = self;
        const r =
            \\HTTP/1.1 200 OK
            \\Content-Encoding: gzip
            \\Content-Type: application/xml
            \\Vary: Accept-Encoding
            \\Last-Modified: Sat, 11 Mar 2023 11:22:28 GMT
            \\Accept-Ranges: bytes
            \\X-Content-Type-Options: nosniff
            \\Date: Mon, 17 Apr 2023 15:23:58 GMT
            \\Server: redbean/2.2.0
            \\Connection: close
            \\Transfer-Encoding: chunked
            \\
        ;
        return r;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

test "http" {
    std.testing.log_level = .debug;
    std.log.info("=> Start http client test\n", .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // const input = "http://localhost:8282/json_feed.json";
    // const input = "http://localhost:8282/many-links.html";
    // const input = "http://github.com/helix-editor/helix/commits/master.atom";
    const input = "http://localhost:8282/rss2.xml";
    // const input = "http://localhost:8282/rss2";
    // const input = "http://localhost:8282/atom.atom";
    // const input = "https://www.google.com/";

    const url = try std.Uri.parse(input);
    var client = Client{ .allocator = arena.allocator() };
    defer client.deinit();
    var req = try FeedRequest.init(&client, url, .{});
    defer req.deinit();
    const body = try req.getBody(arena.allocator());
    defer arena.allocator().free(body);
    print("|{s}|\n", .{body[0..128]});
    // print("=> End http client test\n", .{});
}
