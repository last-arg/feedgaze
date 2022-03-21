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
const expectEqual = std.testing.expectEqual;
const print = std.debug.print;
const Datetime = @import("datetime").datetime.Datetime;
const url_util = @import("url.zig");

pub var general_request_headers = [_]zfetch.Header{
    .{ .name = "Connection", .value = "close" },
    .{ .name = "Accept-Encoding", .value = "gzip" },
    .{ .name = "Accept", .value = "application/atom+xml, application/rss+xml, application/feed+json, text/xml, application/xml, application/json, text/html" },
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
    // zig fmt: on

    pub fn fromString(value: []const u8) ContentType {
        if (ascii.eqlIgnoreCase("text/html", value)) {
            return .html;
        } else if (ascii.eqlIgnoreCase("application/rss+xml", value) or ascii.eqlIgnoreCase("application/x-rss+xml", value)) {
            // NOTE: Just in case check for deprecated mime type 'application/x-rss+xml'
            return .xml_rss;
        } else if (ascii.eqlIgnoreCase("application/atom+xml", value)) {
            return .xml_atom;
        } else if (ascii.eqlIgnoreCase("application/xml", value) or
            ascii.eqlIgnoreCase("text/xml", value))
        {
            return .xml;
        } else if (ascii.eqlIgnoreCase("application/feed+json", value)) {
            return .json_feed;
        } else if (ascii.eqlIgnoreCase("application/json", value)) {
            return .json;
        }
        return .unknown;
    }
};

const max_redirects = 3;

pub fn makeRequest(arena: *ArenaAllocator, url: []const u8, headers: zfetch.Headers) !*zfetch.Request {
    var req = try zfetch.Request.init(arena.allocator(), url, null);
    try req.do(.GET, headers, null);
    return req;
}

pub fn resolveRequest(arena: *ArenaAllocator, url: []const u8, headers_slice: []zfetch.Header) !*zfetch.Request {
    try zfetch.init();
    defer zfetch.deinit(); // Does something on Windows systems. Doesn't allocate anything anyway

    var headers = zfetch.Headers.init(arena.allocator());
    defer headers.deinit();
    try headers.appendSlice(headers_slice);

    var current_url = url;
    var req = try makeRequest(arena, url, headers);
    var redirect_count: u16 = 0;
    while (redirect_count < max_redirects) : (redirect_count += 1) {
        switch (req.status.code) {
            301, 307, 308 => {
                const location = blk: {
                    for (req.headers.list.items) |h| {
                        if (ascii.eqlIgnoreCase("location", h.name)) break :blk h.value;
                    }
                    return error.MissingLocationHeader;
                };
                const uri = try Uri.parse(req.url, true);
                current_url = try url_util.makeWholeUrl(arena.allocator(), uri, location);
                log.info("Redirecting to {s}", .{current_url});
                // Clean old request data
                req.deinit();
                req = try makeRequest(arena, current_url, headers);
            },
            else => break,
        }
    }

    return req;
}

test "resolveRequest()" {
    std.testing.log_level = .debug;
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try zfetch.init();
    defer zfetch.deinit(); // Does something on Windows systems. Doesn't allocate anything anyway

    var headers = [_]zfetch.Header{
        .{ .name = "Connection", .value = "close" },
        .{ .name = "Accept-Encoding", .value = "gzip" },
        .{ .name = "Accept", .value = "application/atom+xml, application/rss+xml, application/feed+json, text/xml, application/xml, application/json, text/html" },
    };

    // url redirects
    const req = try resolveRequest(&arena, "http://localhost:8080/rss2", &headers);
    try expectEqual(req.status.code, 200);
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

pub fn getRequestBody(arena: *ArenaAllocator, req: *zfetch.Request) ![]const u8 {
    const req_reader = req.reader();
    const encoding = req.headers.search("Content-Encoding");

    if (encoding) |enc| {
        if (mem.eql(u8, enc.value, "gzip")) {
            var stream = try std.compress.gzip.gzipStream(arena.allocator(), req_reader);
            defer stream.deinit(); // let ArenaAllocator free all the allocations?
            return try stream.reader().readAllAlloc(arena.allocator(), std.math.maxInt(usize));
        }
        log.warn("Can't handle Content-Encoding {s}. From url {s}", .{ enc.value, req.url });
        return error.UnhandledContentEncoding;
    }

    return try req_reader.readAllAlloc(arena.allocator(), std.math.maxInt(usize));
}

pub fn getContentType(headers: []zfetch.Header) ?[]const u8 {
    var value_opt: ?[]const u8 = null;
    for (headers) |h| {
        if (ascii.eqlIgnoreCase(h.name, "content-type")) {
            value_opt = h.value;
        }
    }

    const value = value_opt orelse return null;
    const end = mem.indexOf(u8, value, ";") orelse value.len;
    return value[0..end];
}
