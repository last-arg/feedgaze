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
    var easy = try curl.Easy.init(.{.default_timeout_ms = 10000, .ca_bundle = try curl.allocCABundle(allocator)});
    errdefer easy.deinit();

    var headers: curl.Easy.Headers = .{};
    try headers.add("Accept: application/atom+xml, application/rss+xml, text/xml, application/xml, text/html");
    
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
    const url_buf_len = 1024;
    var url_buf: [url_buf_len]u8 = undefined;
    std.debug.assert(url.len < url_buf_len);

    const url_with_null = try std.fmt.bufPrintZ(&url_buf, "{s}", .{url});

    var header_buf: [256]u8 = undefined;
    var fb = std.io.fixedBufferStream(&header_buf);
    const w = fb.writer();
    if (opts.etag_or_last_modified) |val| {
        const start = if (val[3] == ',')
            "If-Modified-Since: "
        else
            "If-None-Match: "
        ;
        try w.writeAll(start);
        try w.writeAll(val);
        try w.writeByte(0);
        try self.headers.add(@ptrCast(fb.getWritten()));
    }

    // try self.client.setUrl(url_with_null);
    try self.client.setHeaders(self.headers);
    try self.client.setMaxRedirects(5);
    // Need to unset this if same request is using HEAD (head()) and then GET http method
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_NOBODY, @as(c_long, 0)));
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)));
    const user_agent = "feedgaze/" ++ config.version;
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_USERAGENT, user_agent));
    // try self.client.setVerbose(true);

    // const buffer: curl.Easy.DynamicBuffer = try .initCapacity(self.allocator);
    // errdefer buffer.deinit();
    // try self.client.setWritefunction(curl.Easy.dynamicBufferWriteCallback);
    // try self.client.setWritedata(&buffer);

    // var resp = try self.client.perform();
    const resp = try self.client.fetchAlloc(url_with_null, self.allocator, .{});
    // resp.body = buffer.items;
    return resp;
}

pub fn response_200_and_has_body(resp: curl.Easy.Response, req_url: []const u8) ?[]const u8 {
    if (resp.status_code != 200) {
        std.log.warn("Request to '{s}' failed. Status code: {}", .{req_url, resp.status_code});
        return null;
    }

    if (resp.body == null or resp.body.?.slice().len == 0) {
        std.log.warn("Request to '{s}' failed. There is no body", .{req_url});
        return null;
    }

    return resp.body.?.slice();
}

pub fn fetch_image(self: *@This(), url: []const u8) !struct{curl.Easy.Response, []const u8} {
    const url_buf_len = 1024;
    var url_buf: [url_buf_len]u8 = undefined;
    std.debug.assert(url.len < url_buf_len);

    errdefer |err| {
        if (err != error.InvalidResponse) {
            std.log.warn("Failed to fetch image '{s}'. Error: {}", .{url, err});
        }
    }
    // NOTE: currently head() is only used to check if favicon.ico exists.
    // If in the future am going to use it for something else need to change this.
    try self.headers.add("Accept: image/*");
    
    const url_with_null = try std.fmt.bufPrintZ(&url_buf, "{s}", .{url});
    try self.client.setMaxRedirects(3);
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_NOBODY, @as(c_long, 0)));
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)));
    const user_agent = "feedgaze/" ++ config.version;
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_USERAGENT, user_agent));
    // try self.client.setVerbose(true);

    const resp = try self.client.fetchAlloc(url_with_null, self.allocator, .{});

    const body = response_200_and_has_body(resp, url)
        orelse return error.InvalidResponse;
    
    return .{ resp, body };
}

pub fn resp_to_icon_body(resp: curl.Easy.Response, url: []const u8) ?[]const u8 {
    const body = resp.body orelse {
        std.log.warn("Icon url '{s}' returned no content.", .{url});
        return null;
    };

    if (body.items.len == 0) {
        std.log.warn("Icon url '{s}' returned no content.", .{url});
        return null;
    }

    const max_size = 100 * 1024;
    if (body.items.len >= max_size) {
        std.log.warn("Icon url '{s}' exceeds 100kb size.", .{url});
        return null;
    }

    return body.items;
}

pub fn head(self: *@This(), url: []const u8) !curl.Easy.Response {
    const url_buf_len = 1024;
    var url_buf: [url_buf_len]u8 = undefined;
    std.debug.assert(url.len < url_buf_len);

    // NOTE: currently head() is only used to check if favicon.ico exists.
    // If in the future am going to use it for something else need to change this.
    try self.headers.add("Accept", "image/*");
    
    const url_with_null = try std.fmt.bufPrintZ(&url_buf, "{s}", .{url});
    try self.client.setUrl(url_with_null);
    try self.client.setMaxRedirects(3);
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_NOBODY, @as(c_long, 1)));
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)));
    const user_agent = "feedgaze/" ++ config.version;
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_USERAGENT, user_agent));
    // try self.client.setVerbose(true);

    const resp = try self.client.perform();
    return resp;
}

pub fn get_url_slice(self: *const @This()) ![]const u8 {
    var cstr: [*c]const u8 = undefined;
    try checkCode(
        curl.libcurl.curl_easy_getinfo(self.client.handle, curl.libcurl.CURLINFO_EFFECTIVE_URL, &cstr)
    );
    return std.mem.span(cstr);
}

pub fn checkCode(code: curl.libcurl.CURLcode) !void {
    if (code == curl.libcurl.CURLE_OK) {
        return;
    }

    // https://curl.se/libcurl/c/libcurl-errors.html
    std.log.debug("curl err code: {d}, msg: {s}", .{ code, curl.libcurl.curl_easy_strerror(code) });

    return error.Unexpected;
}
