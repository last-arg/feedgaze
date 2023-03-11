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

// pub const HeaderValues = struct {
//     content_type: ?ContentType = null,
//     etag: ?[]const u8 = null,
//     last_modified: ?i64 = null,
//     expires: ?i64 = null,
//     max_age: ?u32 = null,
//     status: http.Status,

//     pub fn fromResponse(resp: Response) HeaderValues {
//         const etag_key = "etag:";
//         const content_type_key = "content-type:";
//         const last_modified_key = "last-modified:";
//         const expires_key = "expires:";
//         const cache_control_key = "cache-control:";

//         var result: HeaderValues = .{
//             .status = resp.headers.status,
//         };
//         var iter = std.mem.split(u8, resp.header_bytes.items, "\r\n");
//         _ = iter.first();
//         while (iter.next()) |line| {
//             if (std.ascii.startsWithIgnoreCase(line, etag_key)) {
//                 result.etag = std.mem.trim(u8, line[etag_key.len..], " ");
//             } else if (std.ascii.startsWithIgnoreCase(line, content_type_key)) {
//                 result.content_type = ContentType.fromString(std.mem.trim(u8, line[content_type_key.len..], " "));
//             } else if (std.ascii.startsWithIgnoreCase(line, last_modified_key)) {
//                 const raw = std.mem.trim(u8, line[last_modified_key.len..], " ");
//                 result.last_modified = RssDateTime.parse(raw) catch null;
//             } else if (std.ascii.startsWithIgnoreCase(line, expires_key)) {
//                 const raw = std.mem.trim(u8, line[expires_key.len..], " ");
//                 result.expires = RssDateTime.parse(raw) catch null;
//             } else if (std.ascii.startsWithIgnoreCase(line, cache_control_key)) {
//                 var key_value_iter = std.mem.split(u8, line[cache_control_key.len..], ",");
//                 while (key_value_iter.next()) |key_value| {
//                     var pair_iter = mem.split(u8, key_value, "=");
//                     const key = pair_iter.next() orelse continue;
//                     const value = pair_iter.next() orelse continue;
//                     if (mem.eql(u8, "max-age", key)) {
//                         result.max_age = std.fmt.parseUnsigned(u32, value, 10) catch continue;
//                         break;
//                     } else if (mem.eql(u8, "s-maxage", value)) {
//                         result.max_age = std.fmt.parseUnsigned(u32, value, 10) catch continue;
//                     }
//                 }
//             }
//         }
//         return result;
//     }
// };

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
    pub fn fetch(allocator: Allocator, url: Uri, opts: FetchOptions) !void {
        var date_buf: [29]u8 = undefined;
        var bounded = try std.BoundedArray(http.CustomHeader, 3).init(1);
        bounded.buffer[0] = .{ .name = "Accept", .value = "application/atom+xml, application/rss+xml, text/xml, application/xml, text/html" };
        if (opts.etag) |etag| {
            bounded.appendAssumeCapacity(.{ .name = "If-Match", .value = etag });
        }
        if (opts.last_modified_utc) |utc| {
            const date_slice = try datetime.Datetime.formatHttpFromTimestamp(&date_buf, utc);
            bounded.appendAssumeCapacity(.{ .name = "If-Modified-Since", .value = date_slice });
        }

        const headers = Request.Headers{
            .connection = .close,
            .custom = bounded.slice(),
        };
        var client: Client = .{ .allocator = allocator };
        defer client.deinit();
        var req = try client.request(url, headers, .{});
        defer req.deinit();

        const buf_len = 8 * 1024;
        var buf: [buf_len]u8 = undefined;
        try req.waitForCompleteHead();

        // print("|{}|\n", .{req.uri});
        print("|{?s}|\n", .{req.uri.host});
        print("|{s}|\n", .{req.uri.path});
        print("|{?s}|\n", .{req.response.headers.location});
        print("|{s}|\n", .{req.response.header_bytes.items});

        // const header_value = HeaderValues.fromResponse(req.response);
        // const capacity = req.response.headers.content_length orelse buf_len;
        // var content = try std.ArrayList(u8).initCapacity(self.allocator, capacity);
        // defer content.deinit();
        // content.appendSliceAssumeCapacity(buf[0..amt]);

        while (true) {
            const amt = try req.readAll(buf[0..]);
            print("\nAMT: {d}\n", .{amt});
            if (amt == 0) break;
            print("|{s}|", .{buf[0..amt]});
            // try content.appendSlice(buf[0..amt]);
        }
        // print("|{s}|", .{content.items});

        // return .{
        //     .content = try content.toOwnedSlice(),
        //     .headers = header_value,
        // };
    }
};

test "http" {
    std.testing.log_level = .debug;
    print("=> Start http client test\n", .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "http://localhost:8282/rss2.xml";
    const url = try std.Uri.parse(input);
    try FeedRequest.fetch(arena.allocator(), url, .{});
    print("=> End http client test\n", .{});
}
