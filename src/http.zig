const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const Uri = @import("zuri").Uri;
const gzip = std.compress.gzip;
const log = std.log;
const dateStrToTimeStamp = @import("parse.zig").Rss.pubDateToTimestamp;
const zfetch = @import("zfetch");
const expect = std.testing.expect;
const print = std.debug.print;
const Datetime = @import("datetime").datetime.Datetime;

pub const FeedResponse = union(enum) {
    ok: Ok,
    not_modified: void,
    fail: []const u8,
};

const InternalResponse = union(enum) {
    ok: Ok,
    not_modified: void,
    permanent_redirect: PermanentRedirect,
    temporary_redirect: TemporaryRedirect,
    fail: []const u8,
};

const PermanentRedirect = struct {
    location: []const u8,
    msg: []const u8,
};

const TemporaryRedirect = struct {
    location: []const u8,
    msg: []const u8,
    // Need to pass cache related fields to next request
    last_modified: ?[]const u8 = null, // Doesn't own memory
    etag: ?[]const u8 = null, // Doesn't own memory
};

pub const RespHeaders = struct {
    cache_control_max_age: ?u32 = null,
    expires_utc: ?i64 = null,
    etag: ?[]const u8 = null,
    last_modified_utc: ?i64 = null,
};

pub const Ok = struct {
    location: []const u8,
    body: []const u8,
    content_type: ContentType = .unknown,
    headers: RespHeaders = .{},
};

pub const ContentEncoding = enum {
    none,
    gzip,
};

pub const ContentType = enum {
    // zig fmt: off
    xml,       // text/xml
    xml_atom,  // application/atom+xml
    xml_rss,   // application/rss+xml
    json,      // application/json
    json_feed, // application/feed+json
    html,      // text/html
    unknown,
};

const max_redirects = 3;

pub fn resolveRequest(
    arena: *ArenaAllocator,
    url: []const u8,
    last_modified_utc: ?i64,
    etag: ?[]const u8,
) !FeedResponse {
    var date_buf: [29]u8 = undefined;
    const last_modified: ?[]const u8 = if (last_modified_utc) |modified|
        Datetime.formatHttpFromTimestamp(&date_buf, modified) catch null
    else
        null;
    var resp = try makeRequest(arena, url, last_modified, etag);
    var redirect_count: u16 = 0;
    while (redirect_count < max_redirects) : (redirect_count += 1) {
        switch (resp) {
            .ok, .fail, .not_modified => break,
            .permanent_redirect => |perm| {
                log.debug("Permanent redirect to {s}", .{perm.location});
                resp = try makeRequest(arena, perm.location, null, null);
            },
            .temporary_redirect => |temp| {
                log.info("Temporary redirect to {s}", .{temp.location});
                resp = try makeRequest(arena, temp.location, last_modified, etag);
            },
        }
    } else {
        const nr_str = comptime fmt.comptimePrint("{d}", .{max_redirects});
        return FeedResponse{ .fail = "Too many redirects. Max number of redirects allowed is " ++ nr_str };
    }
    std.debug.assert(resp == .ok or resp == .fail);
    return @ptrCast(*FeedResponse, &resp).*;
}

fn isPermanentRedirect(code: u16) bool {
    for ([_]u16{ 301, 307, 308 }) |value| {
        if (code == value) return true;
    }
    return false;
}

pub fn makeRequest(
    arena: *ArenaAllocator,
    url: []const u8,
    last_modified: ?[]const u8,
    etag: ?[]const u8,
) !InternalResponse {
    var allocator = arena.allocator();
    try zfetch.init();
    defer zfetch.deinit(); // Does something on Windows systems. Doesn't allocate anything anyway

    var headers = zfetch.Headers.init(allocator);
    // defer headers.deinit(); // AreanAllocator will clean up all allocations
    const uri = try makeUri(url);
    try headers.appendValue("Host", uri.host.name);
    try headers.appendValue("Connection", "close");
    try headers.appendValue("Accept-Encoding", "gzip");
    try headers.appendValue("Accept", "application/atom+xml, application/rss+xml, application/feed+json, text/xml, application/xml, application/json, text/html");

    if (etag) |value| try headers.appendValue("If-None-Match", value);
    // Ignored if there is 'If-None-Match'
    if (last_modified) |value| try headers.appendValue("If-Modified-Since", value);

    var req = try zfetch.Request.init(allocator, url, null);
    // Closing file socket + freeing allocations
    // defer req.deinit();
    // Only close the file, let AreanAllocator take care of freeing allocations
    defer req.socket.close();

    try req.do(.GET, headers, null);

    if (req.status.code == 200) {
        var result: Ok = undefined;
        result.location = url;
        var content_encoding = ContentEncoding.none;
        var content_length: usize = 128;
        for (req.headers.list.items) |header| {
            // print("{s}: {s}\n", .{ header.name, header.value });
            if (ascii.eqlIgnoreCase("content-length", header.name)) {
                content_length = try fmt.parseInt(u32, header.value, 10);
            } else if (ascii.eqlIgnoreCase("content-type", header.name)) {
                const len = mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
                const value = header.value[0..len];
                if (ascii.eqlIgnoreCase("text/html", value)) {
                    result.content_type = .html;
                } else if (ascii.eqlIgnoreCase("application/rss+xml", value)
                    or ascii.eqlIgnoreCase("application/x-rss+xml", value)) {
                    // NOTE: Just in case check for deprecated mime type 'application/x-rss+xml'
                    result.content_type = .xml_rss;
                } else if (ascii.eqlIgnoreCase("application/atom+xml", value)) {
                    result.content_type = .xml_atom;
                } else if (ascii.eqlIgnoreCase("application/xml", value) or
                    ascii.eqlIgnoreCase("text/xml", value))
                {
                    result.content_type = .xml;
                } else if (ascii.eqlIgnoreCase("application/feed+json", value)) {
                    result.content_type = .json_feed;
                } else if (ascii.eqlIgnoreCase("application/json", value)) {
                    result.content_type = .json;
                }
            } else if (ascii.eqlIgnoreCase("content-encoding", header.name)) {
                var it = mem.split(u8, header.value, ",");
                while (it.next()) |val_raw| {
                    const val = mem.trimLeft(u8, val_raw, " \r\n\t");
                    if (ascii.startsWithIgnoreCase(val, "gzip")) {
                        content_encoding = .gzip;
                        break;
                    }
                }
            } else if (ascii.eqlIgnoreCase("etag", header.name)) {
                result.headers.etag = header.value;
            } else if (ascii.eqlIgnoreCase("last-modified", header.name)) {
                result.headers.last_modified_utc = dateStrToTimeStamp(header.value) catch continue;
            } else if (ascii.eqlIgnoreCase("expires", header.name)) {
                result.headers.expires_utc = dateStrToTimeStamp(header.value) catch continue;
            } else if (ascii.eqlIgnoreCase("cache-control", header.name)) {
                var it = mem.split(u8, header.value, ",");
                while (it.next()) |v_raw| {
                    const v = mem.trimLeft(u8, v_raw, " \r\n\t");
                    if (ascii.startsWithIgnoreCase(v, "max-age") or ascii.startsWithIgnoreCase(v, "s-maxage")) {
                        const eq_index = mem.indexOfScalar(u8, v, '=') orelse continue;
                        result.headers.cache_control_max_age = try fmt.parseInt(u32, v[eq_index + 1 ..], 10);
                        break;
                    }
                }
            }
        }

        const req_reader = req.reader();
        switch (content_encoding) {
            .none => {
                result.body = try req_reader.readAllAlloc(allocator, std.math.maxInt(usize));
            },
            .gzip => {
                var stream = try std.compress.gzip.gzipStream(allocator, req_reader);
                // defer stream.deinit(); // let ArenaAllocator free all the allocations
                result.body = try stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
            },
        }

        return InternalResponse{ .ok = result };
    } else if (isPermanentRedirect(req.status.code)) {
        var permanent_redirect = PermanentRedirect{
            .location = undefined,
            .msg = try fmt.allocPrint(allocator, "{d} {s}", .{ req.status.code, req.status.reason }),
        };

        for (req.headers.list.items) |header| {
            if (ascii.eqlIgnoreCase("location", header.name)) {
                permanent_redirect.location = header.value;
                break;
            }
        }

        return InternalResponse{ .permanent_redirect = permanent_redirect };
    } else if (req.status.code == 302) {
        var temporary_redirect = TemporaryRedirect{
            .location = undefined,
            .last_modified = last_modified,
            .etag = etag,
            .msg = try fmt.allocPrint(allocator, "{d} {s}", .{ req.status.code, req.status.reason }),
        };

        for (req.headers.list.items) |header| {
            if (ascii.eqlIgnoreCase("location", header.name)) {
                temporary_redirect.location = header.value;
                break;
            }
        }

        return InternalResponse{ .temporary_redirect = temporary_redirect };
    } else if (req.status.code == 304) {
        return InternalResponse{ .not_modified = {} };
    }

    const msg = try fmt.allocPrint(allocator, "{d} {s}", .{ req.status.code, req.status.reason });
    return InternalResponse{ .fail = msg };
}

pub fn makeUri(location: []const u8) !Uri {
    var result = try Uri.parse(location, true);
    if (result.scheme.len == 0) result.scheme = "http";
    if (result.path.len == 0) result.path = "/";
    return result;
}

test "makeUri" {
    const url = try makeUri("google.com");
    try std.testing.expectEqualSlices(u8, "http", url.scheme);
    try std.testing.expectEqualSlices(u8, "/", url.path);
}

test "http" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // const url = makeUri("https://google.com") catch unreachable;
    // const url = makeUri("https://news.xbox.com/en-us/feed/") catch unreachable;

    // const r = try resolveRequest(&arena, "https://feeds.feedburner.com/eclipse/fnews", null, null); // gzip
    // const r = try resolveRequest(&arena, "https://www.aruba.it/CMSPages/GetResource.ashx?scriptfile=%2fCMSScripts%2fCustom%2faruba.js", null, null);
    // const r = try resolveRequest(&arena, "https://google.com/", null, null);
    const r = try resolveRequest(&arena, "http://lobste.rs/", null, null);
    // print("{?}\n", .{r});
    if (r == .fail) print("{s}\n", .{r.fail});
}
