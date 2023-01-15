const std = @import("std");
const log = std.log;
const mem = std.mem;
const print = std.debug.print;
const process = std.process;
const Allocator = std.mem.Allocator;
const http = std.http;
const Client = http.Client;

pub const log_level = std.log.Level.debug;

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

    const input = "http://localhost:8080/many-links.html";
    const url = try std.Uri.parse(input);
    var req = try client.request(url, .{}, .{});
    defer req.deinit();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = bw.writer();
    _ = w;

    std.debug.print("{}\n", .{req.response.state});
    var total: usize = 0;
    var buf: [5000]u8 = undefined;
    var amt = try req.readAll(&buf);
    total += amt;

    const header_value = parseHeader(req.response.header_bytes.items);
    parseHtml(buf[0..amt]);
    print("{?s}\n", .{header_value.content_type});
    print("{?s}\n", .{header_value.last_modified});
    print("{?s}\n", .{header_value.etag});

    while (true) {
        std.debug.print("Read start\n", .{});
        amt = try req.readAll(&buf);
        total += amt;
        if (amt == 0) break;
        std.debug.print("  got {d} bytes (total {d})\n", .{ amt, total });
        std.debug.print("{s}\n", .{buf[0..10]});
        // std.debug.print("Read end\n", .{});
    }

    std.debug.print("{}\n", .{req.response});

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
fn parseHtml(input: []const u8) void {
    print("|{s}|\n", .{input});
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
        var end_index = std.mem.indexOfScalar(u8, content, '>') orelse break;
        if (is_link and content[end_index - 1] == '/') {
            end_index -= 1;
        }
        const new_start: usize = if (is_a) 2 else 5;
        var attrs_raw = content[new_start..end_index];
        print("  link: {s}\n", .{attrs_raw});
        while (mem.indexOfScalar(u8, attrs_raw, '=')) |eql_index| {
            const name = std.mem.trimLeft(u8, attrs_raw[0..eql_index], " ");
            print("    name: |{s}|\n", .{name});
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
            print("    value: |{s}|\n", .{value});
        }
    }
    // print("|{s}|\n", .{std.ascii.startsWithIgnoreCase(input)});
}
