const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const twitch = @import("twitch.zig");
const http = @import("http.zig");
const url_util = @import("url.zig");
const Uri = @import("zuri").Uri;
const ArenaAllocator = std.heap.ArenaAllocator;
const zfetch = @import("zfetch");
const log = std.log;
const parse = @import("parse.zig");
const dateStrToTimeStamp = parse.Rss.pubDateToTimestamp;

// TODO?: add field interval (ttl/)
// <sy:updatePeriod>hourly</sy:updatePeriod>
// <sy:updateFrequency>1</sy:updateFrequency>
// has something to do with attributes in xml element
// xmlns:sy="http://purl.org/rss/1.0/modules/syndication/"

// TODO?: move parse.Feed here
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
};

pub const FeedUpdate = struct {
    cache_control_max_age: ?u32 = null,
    expires_utc: ?i64 = null,
    etag: ?[]const u8 = null,
    last_modified_utc: ?i64 = null,

    pub fn fromHeaders(headers: []zfetch.Header) !@This() {
        var result: @This() = .{};
        for (headers) |header| {
            if (ascii.eqlIgnoreCase("etag", header.name)) {
                result.etag = header.value;
            } else if (ascii.eqlIgnoreCase("last-modified", header.name)) {
                result.last_modified_utc = dateStrToTimeStamp(header.value) catch continue;
            } else if (ascii.eqlIgnoreCase("expires", header.name)) {
                result.expires_utc = dateStrToTimeStamp(header.value) catch continue;
            } else if (ascii.eqlIgnoreCase("cache-control", header.name)) {
                var it = mem.split(u8, header.value, ",");
                while (it.next()) |v_raw| {
                    const v = mem.trimLeft(u8, v_raw, " \r\n\t");
                    if (ascii.startsWithIgnoreCase(v, "max-age") or ascii.startsWithIgnoreCase(v, "s-maxage")) {
                        const eq_index = mem.indexOfScalar(u8, v, '=') orelse continue;
                        result.cache_control_max_age = try fmt.parseInt(u32, v[eq_index + 1 ..], 10);
                        break;
                    }
                }
            }
        }
        return result;
    }
};
