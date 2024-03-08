const std = @import("std");
const datetime = @import("zig-datetime").datetime;
const feed_types = @import("./feed_types.zig");
const ContentType = feed_types.ContentType;
const RssDateTime = feed_types.RssDateTime;
const FetchHeaderOptions = feed_types.FetchHeaderOptions;
const FeedUpdate = feed_types.FeedUpdate;
const http = std.http;
const mem = std.mem;
const print = std.debug.print;
const Client = http.Client;
const Allocator = mem.Allocator;
const Request = http.Client.Request;
const Response = http.Client.Response;
const Uri = std.Uri;
const assert = std.debug.assert;
const curl = @import("curl");

allocator: Allocator,
headers: curl.Easy.Headers,
client: curl.Easy,

pub fn init(allocator: Allocator) !@This() {
    var easy = try curl.Easy.init(allocator, .{.default_timeout_ms = 5000});
    errdefer easy.deinit();

    var headers = try easy.create_headers();
    errdefer headers.deinit();
    try headers.add("Accept", "application/atom+xml, application/rss+xml, text/xml, application/xml, text/html");
    // Some sites require User-Agent, otherwise will be blocked.
    // TODO: make version into variable and use it here
    // try headers.add("User-Agent", "feedgaze/0.1.0");
    
    return .{
        .allocator = allocator,
        .headers = headers,
        .client = easy,
    };
}

pub fn deinit(self: *@This()) void {
    self.headers.deinit();
    self.client.deinit();
}

pub fn fetch(self: *@This(), url: []const u8, opts: FetchHeaderOptions) !curl.Easy.Response {
    const url_null = try self.allocator.dupeZ(u8, url);

    if (opts.etag) |etag| {
        try self.headers.add("If-None-Match", etag);
    } else {
        var date_buf: [29]u8 = undefined;
        if (opts.last_modified_utc) |utc| {
            const date_slice = try datetime.Datetime.formatHttpFromTimestamp(&date_buf, utc * 1000);
            // TODO: move date_buf outside of condition, should not need allocator
            try self.headers.add("If-Modified-Since", try self.allocator.dupe(u8, date_slice));
        }
    }

    try self.client.set_url(url_null);
    try self.client.set_headers(self.headers);
    try self.client.set_max_redirects(5);
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)));
    // try self.client.set_verbose(true);

    return try self.client.perform();
}

pub fn checkCode(code: curl.libcurl.CURLcode) !void {
    if (code == curl.libcurl.CURLE_OK) {
        return;
    }

    // https://curl.se/libcurl/c/libcurl-errors.html
    std.log.debug("curl err code:{d}, msg:{s}\n", .{ code, curl.libcurl.curl_easy_strerror(code) });

    return error.Unexpected;
}
