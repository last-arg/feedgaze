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
const Uri = std.Uri;
const assert = std.debug.assert;
const curl = @import("curl");
pub const Response = curl.Easy.Response;

client: http.Client,
response: ?http.Client.Response = null,
request: ?http.Client.Request = null,

pub fn init(allocator: Allocator) !@This() {
    var client: http.Client = .{
        .allocator = allocator,
    };
    errdefer client.deinit();

    return .{
        .client = client,
    };
}

pub fn deinit(self: *@This()) void {
    if (self.request) |*req| {
        req.deinit();
    }
    self.client.deinit();
}

pub fn fetch(self: *@This(), url: []const u8, opts: FetchHeaderOptions) !http.Client.Response {
    const uri = try std.Uri.parse(url);

    var request_opts: std.http.Client.RequestOptions = .{
        .redirect_behavior = .init(5),
        .headers = .{
            .content_type = .{ .override = "application/atom+xml, application/rss+xml, text/xml, application/xml, text/html" },
        },
    };

    if (opts.etag_or_last_modified) |val| {
        const h: http.Header = .{
            .name = if (val[3] == ',')
                "If-Modified-Since"
            else
                "If-None-Match"
            ,
            .value = val,
        };

        request_opts.extra_headers = &.{ h };
    }

    self.request = try self.client.request(.GET, uri, request_opts);
    errdefer self.request.?.deinit();

    try self.request.?.sendBodiless();

    self.response = try self.request.?.receiveHead(opts.buffer_header);
    
    return self.response.?;
}

pub const CacheControl = struct {
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    update_interval: i64 = @import("./app_config.zig").update_interval,
};

pub fn parse_headers(bytes: []const u8) !CacheControl {
    var result: CacheControl = .{};
    var iter = mem.splitSequence(u8, bytes, "\r\n");
    _ = iter.first();

    while (iter.next()) |line| {
        if (line.len == 0) return result;
        switch (line[0]) {
            ' ', '\t' => return error.HttpHeaderContinuationsUnsupported,
            else => {},
        }

        var line_it = mem.splitScalar(u8, line, ':');
        const header_name = line_it.next().?;
        const header_value = mem.trim(u8, line_it.rest(), " \t");
        if (header_name.len == 0) return error.HttpHeadersInvalid;

        if (std.ascii.eqlIgnoreCase(header_name, "etag")) {
            result.etag = header_value;
        } else if (result.etag == null and std.ascii.eqlIgnoreCase(header_name, "last-modified")) {
            result.last_modified = header_value;
        } else if (std.ascii.eqlIgnoreCase(header_name, "cache-control")) {
            const value = header_value;
            var iter_value = std.mem.splitScalar(u8, value, ',');
            while (iter_value.next()) |key_value| {
                var pair_iter = std.mem.splitScalar(u8, key_value, '=');
                var key = pair_iter.next() orelse continue;
                key = std.mem.trim(u8, key, &std.ascii.whitespace);
                if (std.mem.eql(u8, "no-cache", key)) {
                    break;
                }
                var value_part = pair_iter.next() orelse continue;
                value_part = std.mem.trim(u8, value_part, &std.ascii.whitespace);

                if (std.mem.eql(u8, "max-age", key)) {
                    result.update_interval = std.fmt.parseUnsigned(u32, value_part, 10) catch continue;
                } else if (std.mem.eql(u8, "s-maxage", value)) {
                    result.update_interval = std.fmt.parseUnsigned(u32, value_part, 10) catch continue;
                    break;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(header_name, "expires")) {
            const value = RssDateTime.parse(header_value) catch null;
            if (value) |v| {
                const interval = v - std.time.timestamp();
                // Favour cache-control value over expires
                if (interval > 0) {
                    result.update_interval = interval;
                }
            }
        }
    }

    return result;
}

pub fn read_body(response: *http.Client.Response, writer: *std.Io.Writer, allocator: Allocator) ![]const u8  {
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    _ = reader.streamRemaining(writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return writer.buffered();
}


pub fn handle_response(response: *http.Client.Response, writer: *std.Io.Writer, allocator: Allocator) !?FeedUpdate {
    print("http status: {}\n", .{response.head.status});
    if (response.head.status != .ok) {
        return null;
    }

    const headers = try parse_headers(response.head.bytes);
    var result: FeedUpdate = .{
        .update_interval = headers.update_interval,
    };

    if (headers.etag orelse headers.last_modified) |val| {
        result.etag_or_last_modified = try allocator.dupe(u8, val);
    } 

    _ = try read_body(response, writer, allocator);

    return result;
}

pub fn response_200_and_has_body(self: *const @This(), req_url: []const u8) ?[]const u8 {
    assert(self.resp != null);
    const resp = self.resp orelse unreachable;
    if (resp.status_code != 200) {
        std.log.warn("Request to '{s}' failed. Status code: {}", .{req_url, resp.status_code});
        return null;
    }

    const body = self.writer.writer.buffered();
    // On 'https://statmodeling.stat.columbia.edu/favicon.ico' got empty body.
    if (body.len == 0) {
        return null;
    }

    return body;
}

pub fn fetch_image(self: *@This(), url: []const u8, opts: FetchHeaderOptions) !void {
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

    var header_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&header_buf);

    if (opts.etag_or_last_modified) |val| {
        const start = if (val[3] == ',')
            "If-Modified-Since: "
        else
            "If-None-Match: "
        ;
        try w.writeAll(start);
        try w.writeAll(val);
        try w.writeByte(0);
        try self.headers.add(@ptrCast(w.buffered()));
    }

    try self.client.setHeaders(self.headers);
    
    try self.client.setMaxRedirects(3);
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_NOBODY, @as(c_long, 0)));
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)));
    const user_agent = "feedgaze/" ++ config.version;
    try checkCode(curl.libcurl.curl_easy_setopt(self.client.handle, curl.libcurl.CURLOPT_USERAGENT, user_agent));
    // try self.client.setVerbose(true);

    const url_with_null = try std.fmt.bufPrintZ(&url_buf, "{s}", .{url});
    self.resp = try self.client.fetch(url_with_null, .{
         .writer = &self.writer.writer,
    });
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

pub fn etag_or_last_modified_from_resp(resp: @import("curl").Easy.Response) !?[]const u8 {
    const header = try resp.getHeader("etag") orelse try resp.getHeader("etag");
    if (header) |h| {
        return h.get();
    }
    return null;
}
