const std = @import("std");
const datetime = @import("zig-datetime").datetime;
const feed_types = @import("./feed_types.zig");
const ContentType = feed_types.ContentType;
const RssDateTime = feed_types.RssDateTime;
const FetchHeaderOptions = feed_types.FetchHeaderOptions;
const FeedUpdate = feed_types.FeedUpdate;
const http = std.http;
const config = @import("./app_config.zig");
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
    var easy = try curl.Easy.init(allocator, .{.default_timeout_ms = 10000});
    errdefer easy.deinit();

    var headers = try easy.create_headers();
    errdefer headers.deinit();
    try headers.add("Accept", "application/atom+xml, application/rss+xml, text/xml, application/xml, text/html");
    
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
    var date_buf: [29]u8 = undefined;
    const url_buf_len = 1024;
    var url_buf: [url_buf_len]u8 = undefined;
    std.debug.assert(url.len < url_buf_len);

    const url_with_null = try std.fmt.bufPrintZ(&url_buf, "{s}", .{url});

    if (opts.etag) |etag| {
        try self.headers.add("If-None-Match", etag);
    } else {
        if (opts.last_modified_utc) |utc| {
            const date_slice = try datetime.Datetime.formatHttpFromTimestamp(&date_buf, utc * 1000);
            try self.headers.add("If-Modified-Since", date_slice);
        }
    }

    try self.client.set_url(url_with_null);
    try self.client.set_headers(self.headers);
    try self.client.set_max_redirects(5);
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)));
    const user_agent = "feedgaze/" ++ config.version;
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_USERAGENT, user_agent));
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
