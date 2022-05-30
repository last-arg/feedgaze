const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const Uri = @import("zuri").Uri;
const log = std.log;
const dateStrToTimeStamp = @import("parse.zig").Rss.pubDateToTimestamp;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const print = std.debug.print;
const Datetime = @import("datetime").datetime.Datetime;
const url_util = @import("url.zig");
const curl = @import("curl_extend.zig");

pub const base_headers = [_][]const u8{
    "Accept: application/atom+xml, application/rss+xml, application/feed+json, text/xml, application/xml, application/json, text/html",
    "User-Agent: feedgaze 0.1.0",
};
pub var general_request_headers_curl = base_headers;

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

const Fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} });
pub const Response = struct {
    status_code: isize,
    headers_fifo: Fifo,
    body_fifo: Fifo,
    allocator: std.mem.Allocator,
    url: ?[]const u8 = null,

    pub fn deinit(self: *@This()) void {
        self.headers_fifo.deinit();
        self.body_fifo.deinit();
        if (self.url) |url| self.allocator.free(url);
    }
};

pub const RequestOptions = struct {
    follow: bool = true,
    headers: [][]const u8 = &general_request_headers_curl,
    post_data: ?[]u8 = null, // At the moment only used when testing server.zig code
};

pub fn resolveRequestCurl(arena: *ArenaAllocator, raw_url: []const u8, opts: RequestOptions) !Response {
    var body_fifo = Fifo.init(arena.allocator());
    var headers_fifo = Fifo.init(arena.allocator());

    var headers = curl.HeaderList.init();
    defer headers.freeAll();
    var stack_alloc = std.heap.stackFallback(128, arena.allocator());
    for (opts.headers) |header| {
        const header_null = try stack_alloc.get().dupeZ(u8, header);
        try headers.append(header_null);
    }

    const easy = try curl.Easy.init();
    defer easy.cleanup();

    const url = try stack_alloc.get().dupeZ(u8, raw_url);

    try easy.setUrl(url);
    try easy.setAcceptEncodingGzip();
    try easy.setFollowLocation(opts.follow);
    try easy.setHeaders(headers);
    try easy.setSslVerifyPeer(false);
    try curl.setHeaderWriteFn(easy, curl.writeToFifo(Fifo));
    try curl.setHeaderWriteData(easy, &headers_fifo);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&body_fifo);
    if (opts.post_data) |*data| {
        try easy.setPostFields(data.ptr);
        try easy.setPostFieldSize(data.len);
    }
    try easy.setVerbose(false);
    try easy.perform();

    var resp = Response{
        .status_code = try easy.getResponseCode(),
        .headers_fifo = headers_fifo,
        .body_fifo = body_fifo,
        .allocator = arena.allocator(),
    };

    if (try curl.getEffectiveUrl(easy)) |val| {
        print("val: {s} | span: {s}\n", .{ val, mem.span(val) });
        resp.url = try arena.allocator().dupe(u8, "test");
    }

    return resp;
}

test "resolveRequestCurl()" {
    std.testing.log_level = .debug;
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try curl.globalInit();
    defer curl.globalCleanup();

    // url redirects
    var headers = general_request_headers_curl;
    const req = try resolveRequestCurl(&arena, "http://localhost:8080/rss2", .{ .headers = &headers });
    try expectEqual(req.status_code, 200);
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
