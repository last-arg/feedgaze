const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
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

// 1. insert url
// 2. valid url. return response
// 3. redirected. go to step 1
// 4. returned content-type == "text/html"
//   - parse html for rss links
//   - if one link/url found go to step 1
//   - more than one link ask which link/url to add and go to step 1
// 5. Not valid feed url and failed to find a valid feed url.

pub const FeedRequest = struct {
    url: Uri,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
};

const FeedResponse = union(enum) {
    success: Success,
    not_modified: void,
    permanent_redirect: PermanentRedirect,
    temporary_redirect: TemporaryRedirect,
    fail: []const u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        switch (self) {
            .success => |s| s.deinit(allocator),
            .not_modified => {},
            .permanent_redirect => |perm| perm.deinit(allocator),
            .temporary_redirect => |temp| temp.deinit(allocator),
            .fail => |value| allocator.free(value),
        }
    }
};

const PermanentRedirect = struct {
    location: []const u8,
    msg: []const u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.location);
        allocator.free(self.msg);
    }
};

const TemporaryRedirect = struct {
    location: []const u8,
    // Need to pass cache related fields to next request
    last_modified: ?[]const u8 = null, // Doesn't own memory
    etag: ?[]const u8 = null, // Doesn't own memory
    msg: []const u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.location);
        allocator.free(self.msg);
    }
};

const Success = struct {
    location: []const u8,
    body: []const u8,
    content_type: ContentType = .unknown,

    cache_control_max_age: ?usize = null,
    expires_utc: ?i64 = null,
    etag: ?[]const u8 = null,
    last_modified_utc: ?i64 = null,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.location);
        allocator.free(self.body);
        if (self.etag) |value| allocator.free(value);
    }
};

pub const ContentEncoding = enum {
    none,
    gzip,
};

pub const TransferEncoding = enum {
    none,
    chunked,
};

pub const ContentType = enum {
    xml, // text/xml
    xml_atom, // application/atom+xml
    xml_rss, // application/rss+xml
    // TODO: add new content types
    // json, // application/json
    // json_feed, // application/feed+json
    html, // text/html
    unknown,
};

const max_redirects = 3;
pub fn resolveRequest(
    allocator: Allocator,
    url: []const u8,
    last_modified: ?[]const u8,
    etag: ?[]const u8,
) !FeedResponse {
    var resp = try makeRequest(allocator, url, last_modified, etag);
    errdefer resp.deinit(allocator);
    var redirect_count: u16 = 0;
    while (redirect_count < max_redirects) : (redirect_count += 1) {
        switch (resp) {
            .success, .fail, .not_modified => break,
            .permanent_redirect => |perm| {
                log.debug("Permanent redirect to {s}", .{perm.location});
                resp = try makeRequest(allocator, perm.location, null, null);
            },
            .temporary_redirect => |temp| {
                log.info("Temporary redirect to {s}", .{temp.location});
                resp = try makeRequest(allocator, temp.location, temp.last_modified, temp.etag);
            },
        }
    } else {
        return FeedResponse{ .fail = try fmt.allocPrint(allocator, "Too many redirects", .{}) };
    }
    return resp;
}

fn isPermanentRedirect(code: u16) bool {
    for ([_]u16{ 301, 307, 308 }) |value| {
        if (code == value) return true;
    }
    return false;
}

pub fn makeRequest(
    allocator: Allocator,
    url: []const u8,
    last_modified: ?[]const u8,
    etag: ?[]const u8,
) !FeedResponse {
    print("URL: {s}\n", .{url});
    try zfetch.init();
    defer zfetch.deinit();

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();
    const uri = try makeUri(url);
    try headers.appendValue("Host", uri.host.name);
    try headers.appendValue("Connection", "close");
    try headers.appendValue("Accept-Encoding", "gzip");
    try headers.appendValue("Accept", "application/rss+xml, application/atom+xml, application/feed+json, application/json, text/xml, application/xml, text/html");

    if (etag) |value| try headers.appendValue("If-None-Match", value);
    if (last_modified) |value| try headers.appendValue("If-Modified-Since", value);

    var req = try zfetch.Request.init(allocator, url, null);
    defer req.deinit();

    try req.do(.GET, headers, null);

    if (req.status.code == 200) {
        var result: Success = undefined;
        result.location = url;
        var content_encoding = ContentEncoding.none;
        var content_length: usize = 128;
        for (req.headers.list.items) |header| {
            print("{s}: {s}\n", .{ header.name, header.value });
            // TODO: parse other header names and values
            if (ascii.eqlIgnoreCase("content-length", header.name)) {
                content_length = try fmt.parseInt(u32, header.value, 10);
            } else if (ascii.eqlIgnoreCase("content-type", header.name)) {
                const len = mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
                const value = header.value[0..len];
                if (ascii.eqlIgnoreCase("text/html", value)) {
                    result.content_type = .html;
                } else if (ascii.eqlIgnoreCase("application/rss+xml", value)) {
                    result.content_type = .xml_rss;
                } else if (ascii.eqlIgnoreCase("application/atom+xml", value)) {
                    result.content_type = .xml_atom;
                } else if (ascii.eqlIgnoreCase("application/xml", value) or
                    ascii.eqlIgnoreCase("text/xml", value))
                {
                    result.content_type = .xml;
                }
                // TODO: new ContentType enums
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
                result.etag = mem.Allocator.dupe(allocator, u8, header.value) catch continue;
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
                        result.cache_control_max_age = try fmt.parseInt(usize, v[eq_index + 1 ..], 10);
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
                defer stream.deinit();
                result.body = try stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
            },
        }

        return FeedResponse{ .success = result };
    } else if (isPermanentRedirect(req.status.code)) {
        var permanent_redirect = PermanentRedirect{
            .location = undefined,
            .msg = try fmt.allocPrint(allocator, "{d} {s}", .{ req.status.code, req.status.reason }),
        };

        for (req.headers.list.items) |header| {
            if (ascii.eqlIgnoreCase("location", header.name)) {
                permanent_redirect.location = try mem.Allocator.dupe(allocator, u8, header.value);
                break;
            }
        }

        return FeedResponse{ .permanent_redirect = permanent_redirect };
    } else if (req.status.code == 302) {
        var temporary_redirect = TemporaryRedirect{
            .location = undefined,
            .last_modified = last_modified,
            .etag = etag,
            .msg = try fmt.allocPrint(allocator, "{d} {s}", .{ req.status.code, req.status.reason }),
        };

        for (req.headers.list.items) |header| {
            if (ascii.eqlIgnoreCase("location", header.name)) {
                temporary_redirect.location = try mem.Allocator.dupe(allocator, u8, header.value);
                break;
            }
        }

        return FeedResponse{ .temporary_redirect = temporary_redirect };
    } else if (req.status.code == 304) {
        return FeedResponse{ .not_modified = {} };
    }

    const msg = try fmt.allocPrint(allocator, "{d} {s}", .{ req.status.code, req.status.reason });
    return FeedResponse{ .fail = msg };
}

pub fn makeUri(location: []const u8) !Uri {
    var result = try Uri.parse(location, true);

    if (result.scheme.len == 0) {
        result.scheme = "http";
    }

    if (result.path.len == 0) {
        result.path = "/";
    }
    return result;
}

test "http" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // const url = makeUri("http://google.com/") catch unreachable;
    // const url = makeUri("http://lobste.rs") catch unreachable;
    // const url = makeUri("https://www.aruba.it/CMSPages/GetResource.ashx?scriptfile=%2fCMSScripts%2fCustom%2faruba.js") catch unreachable; // chunked + deflate
    // const url = makeUri("https://news.xbox.com/en-us/feed/") catch unreachable;
    // const url = makeUri("https://feeds.feedburner.com/eclipse/fnews") catch unreachable;

    // const rand = std.rand;
    // var r = rand.DefaultPrng.init(@intCast(u64, std.time.milliTimestamp()));
    // l.warn("rand: {}", .{r.random.int(u8)});

    // const req = FeedRequest{ .url = url };
    // _ = try resolveRequest(allocator, req);

    // const r = makeRequest(allocator, "https://feeds.feedburner.com/eclipse/fnews", null, null); // gzip
    // const r = makeRequest(allocator, "https://www.aruba.it/CMSPages/GetResource.ashx?scriptfile=%2fCMSScripts%2fCustom%2faruba.js", null, null);
    // const r = makeRequest(allocator, "https://google.com/", null, null);
    const r = try resolveRequest(allocator, "http://lobste.rs/", null, null);
    defer r.deinit(allocator);
    print("{?}\n", .{r});
}
