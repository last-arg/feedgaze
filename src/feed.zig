const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const twitch = @import("twitch.zig");
const http = @import("http.zig");
const url_util = @import("url.zig");
const Uri = @import("zuri").Uri;
const ArenaAllocator = std.heap.ArenaAllocator;
const log = std.log;
const parse = @import("parse.zig");
const dateStrToTimeStamp = parse.Rss.pubDateToTimestamp;

pub const Feed = struct {
    const Self = @This();
    // Atom: title (required)
    // Rss: title (required)
    title: []const u8,
    // Atom: updated (required)
    // Rss: pubDate (optional)
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,
    // Atom: optional
    // Rss: required
    link: ?[]const u8 = null,
    location: []const u8 = "",
    items: []Item = &[_]Item{},
    interval_sec: ?u32 = null,

    pub const Item = struct {
        // Atom: title (required)
        // Rss: title or description (requires one of these)
        title: []const u8,
        // Atom: id (required). Has to be URI.
        // Rss: guid (optional) or link (optional)
        id: ?[]const u8 = null,
        // In atom id (required) can also be link.
        // Check if id is link before outputing some data
        // Atom: link (optional),
        // Rss: link (optional)
        link: ?[]const u8 = null,
        // Atom: updated (required) or published (optional)
        // Rss: pubDate (optional)
        updated_raw: ?[]const u8 = null,
        updated_timestamp: ?i64 = null,
    };

    pub fn initParse(arena: *ArenaAllocator, location: []const u8, body: []const u8, content_type: http.ContentType) !@This() {
        var feed = switch (content_type) {
            .xml => try parse.parse(arena, body),
            .xml_atom => try parse.Atom.parse(arena, body),
            .xml_rss => try parse.Rss.parse(arena, body),
            .json, .json_feed => try parse.Json.parse(arena, body),
            .html, .unknown => return error.CantParse,
        };
        feed.location = location;
        return feed;
    }
};

pub const FeedUpdate = struct {
    cache_control_max_age: ?u32 = null,
    expires_utc: ?i64 = null,
    etag: ?[]const u8 = null,
    last_modified_utc: ?i64 = null,

    pub fn fromHeadersCurl(header: []const u8) !@This() {
        const etag_key = "etag";
        const last_modified_key = "last-modified";
        const expires_key = "expires";
        const cache_control_key = "cache-control";
        var result: @This() = .{};
        var iter = mem.split(u8, header, "\r\n");
        while (iter.next()) |line| {
            if (ascii.startsWithIgnoreCase(line, etag_key)) {
                result.etag = mem.trim(u8, line[etag_key.len + 1 ..], "\r\n ");
            } else if (ascii.startsWithIgnoreCase(line, last_modified_key)) {
                const val = mem.trim(u8, line[last_modified_key.len + 1 ..], "\r\n ");
                result.last_modified_utc = dateStrToTimeStamp(val) catch continue;
            } else if (ascii.startsWithIgnoreCase(line, expires_key)) {
                const val = mem.trim(u8, line[expires_key.len + 1 ..], "\r\n ");
                // TODO?: Don't use expires value if it is now (current) or close to it
                result.expires_utc = dateStrToTimeStamp(val) catch continue;
            } else if (ascii.startsWithIgnoreCase(line, cache_control_key)) {
                const raw_values = line[expires_key.len + 1 ..];
                var iter_value = mem.split(u8, raw_values, ",");
                while (iter_value.next()) |raw_value| {
                    const value = mem.trimLeft(u8, raw_value, " \r\n\t");
                    if (ascii.startsWithIgnoreCase(value, "max-age") or ascii.startsWithIgnoreCase(value, "s-maxage")) {
                        // TODO?: move this check to somewhere else? Before entering DB?
                        const eq_index = mem.indexOfScalar(u8, value, '=') orelse continue;
                        const nr = fmt.parseInt(u32, value[eq_index + 1 ..], 10) catch break;
                        if (nr > 0) result.cache_control_max_age = nr;
                        break;
                    }
                }
            }
        }
        return result;
    }
};
