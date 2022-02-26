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

// TODO?: move parse.Feed here
pub const Feed = struct {
    // TODO?: combine with or remove http.RespHeaders?
    pub const Update = http.RespHeaders;
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
