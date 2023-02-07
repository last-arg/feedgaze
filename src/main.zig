const std = @import("std");
const log = std.log;
const mem = std.mem;
const print = std.debug.print;
const process = std.process;
const Allocator = std.mem.Allocator;
const http = std.http;
const Client = http.Client;

pub const log_level = std.log.Level.debug;

const FeedLink = struct {
    link: []const u8,
    type: Type,
    title: ?[]const u8 = null,

    const Type = enum {
        rss,
        atom,
        xml,

        fn fromString(input: []const u8) ?Type {
            if (std.ascii.eqlIgnoreCase(input, "application/rss+xml")) {
                return .rss;
            } else if (std.ascii.eqlIgnoreCase(input, "application/atom+xml")) {
                return .atom;
            } else if (std.ascii.eqlIgnoreCase(input, "application/xml") or std.ascii.eqlIgnoreCase(input, "text/xml")) {
                return .xml;
            }
            return null;
        }
    };
};
const FeedLinkArray = std.ArrayList(FeedLink);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const base_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var client: Client = .{
        .allocator = arena_allocator,
    };
    try client.ca_bundle.rescan(arena_allocator);

    const input = "http://localhost:8282/many-links.html";
    const url = try std.Uri.parse(input);
    var req = try client.request(url, .{}, .{});
    defer req.deinit();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = bw.writer();
    _ = w;

    std.debug.print("{}\n", .{req.response.state});
    var total: usize = 0;
    // NOTE: if there is no '>' symbol found in buf, will skip parsing.
    // Make sure buf is big enough to hold <a> or <link> attributes in buffer.
    var buf: [4 * 100]u8 = undefined;
    var buf_len: usize = 0;
    var amt = try req.readAll(&buf);
    total += amt;

    const header_value = parseHeader(req.response.header_bytes.items);
    print("{?s}\n", .{header_value.content_type});
    print("{?s}\n", .{header_value.last_modified});
    print("{?s}\n", .{header_value.etag});

    var feed_links = try FeedLinkArray.initCapacity(arena_allocator, 3);
    defer feed_links.deinit();

    buf_len = if (mem.lastIndexOfScalar(u8, buf[0..amt], '>')) |last_lne_sign|
        last_lne_sign + @boolToInt(last_lne_sign < amt)
    else
        0;

    const len = if (buf_len == 0) amt else buf_len;
    try parseHtmlForFeedLinks(buf[0..len], &feed_links);
    // TODO: prefill start of buf with characters after last_lne_sign
    if (buf_len != 0) {
        mem.copy(u8, buf[0..], buf[buf_len..]);
        buf_len = amt - buf_len;
    }

    while (true) {
        // std.debug.print("Read start\n", .{});
        amt = try req.readAll(buf[buf_len..]);
        total += amt;
        // std.debug.print("  got {d} bytes (total {d})\n", .{ amt, total });
        if (amt == 0) break;
        const new_len = buf_len + amt;
        buf_len = if (mem.lastIndexOfScalar(u8, buf[0..new_len], '>')) |last_lne_sign|
            last_lne_sign + @boolToInt(last_lne_sign < amt)
        else
            0;
        try parseHtmlForFeedLinks(buf[0..new_len], &feed_links);
        if (buf_len != 0) {
            mem.copy(u8, &buf, buf[buf_len..new_len]);
            buf_len = new_len - buf_len;
        }
        // std.debug.print("{s}\n", .{buf[0..amt]});
        // std.debug.print("Read end\n", .{});
    }

    for (feed_links.items) |link| {
        print("link: {s}\n", .{link.link});
        print("type: {}\n", .{link.type});
        print("title: {?s}\n", .{link.title});
    }

    // std.debug.print("{}\n", .{req.response});

    try bw.flush();

    log.info("END", .{});
}

// Last-Modified (If-Modified-Since)
// length 29
//
// ETag (If-Match)
// Has no set length. Set it to 128?
//
// Content-Type

const HeaderValues = struct {
    content_type: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
};

fn parseHeader(raw_header: []const u8) HeaderValues {
    const etag_key = "etag:";
    const content_type_key = "content-type:";
    const last_modified_key = "last-modified:";

    var result: HeaderValues = .{};
    var iter = std.mem.split(u8, raw_header, "\r\n");
    _ = iter.first();
    while (iter.next()) |line| {
        std.debug.print("|{s}|\n", .{line});
        if (std.ascii.startsWithIgnoreCase(line, etag_key)) {
            result.etag = std.mem.trim(u8, line[etag_key.len..], " ");
        } else if (std.ascii.startsWithIgnoreCase(line, content_type_key)) {
            result.content_type = std.mem.trim(u8, line[content_type_key.len..], " ");
        } else if (std.ascii.startsWithIgnoreCase(line, last_modified_key)) {
            result.last_modified = std.mem.trim(u8, line[last_modified_key.len..], " ");
        }
    }
    return result;
}

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
