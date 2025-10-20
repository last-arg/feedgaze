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

client: http.Client,
response: ?http.Client.Response = null,
request: ?http.Client.Request = null,

pub const Response = http.Client.Response;
pub const HeaderMap = std.ArrayHashMap([]const u8, []const u8, StringContext, true);

const StringContext = struct {
    pub fn hash(self: @This(), s: []const u8) u32 {
        _ = self;
        return std.array_hash_map.hashString(s);
    }
    pub fn eql(self: @This(), a: []const u8, b: []const u8, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

pub fn init(allocator: Allocator) @This() {
    const client: http.Client = .{
        .allocator = allocator,
    };

    return .{
        .client = client,
    };
}

pub fn deinit(self: *@This()) void {
    self.response = null;
    if (self.request) |*req| {
        req.deinit();
        self.request = null;
    }
    self.client.deinit();
}

pub fn fetch(self: *@This(), writer: *std.Io.Writer, allocator: Allocator, url: []const u8, opts: FetchHeaderOptions) !?feed_types.FeedOptions {
    var resp = try self.fetch_response(url, opts);
    const re = try handle_response(&resp, writer, allocator);
    return re;
}

pub fn fetch_response(self: *@This(), url: []const u8, opts: FetchHeaderOptions) !http.Client.Response {
    const uri = try std.Uri.parse(url);
    var extra_headers_arr: [2]std.http.Header = undefined;
    extra_headers_arr[0] = .{ .name = "Accept", .value = "application/atom+xml, application/rss+xml, text/xml, application/xml, text/html" };

    var request_opts: std.http.Client.RequestOptions = .{
        .keep_alive = false,
        .redirect_behavior = .init(5),
        .extra_headers = extra_headers_arr[0..1],
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
        extra_headers_arr[1] = h;

        request_opts.extra_headers = &extra_headers_arr;
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

pub fn handle_response(response: *http.Client.Response, writer: *std.Io.Writer, allocator: Allocator) !?feed_types.FeedOptions {
    if (response.head.status != .ok) {
        return null;
    }

    const headers = try parse_headers(response.head.bytes);
    var result: feed_types.FeedOptions = .{
        .feed_updates = .{
            .update_interval = headers.update_interval,
        },
    };

    if (response.head.content_type) |ct|{
        result.content_type = ContentType.fromString(ct);
    }

    if (headers.etag orelse headers.last_modified) |val| {
        result.feed_updates.etag_or_last_modified = try allocator.dupe(u8, val);
    } 

    _ = try read_body(response, writer, allocator);

    return result;
}

pub fn handle_image_response(response: *http.Client.Response, writer: *std.Io.Writer, allocator: Allocator) !?CacheControl {
    if (response.head.status != .ok) {
        return null;
    }

    var headers = try parse_headers(response.head.bytes);
    var result: CacheControl = .{
        .update_interval = 0,
    };

    if (headers.etag) |val| {
        result.etag = try allocator.dupe(u8, val);
    } else if (headers.last_modified) |val| {
        result.last_modified = try allocator.dupe(u8, val);
    } 

    _ = try read_body(response, writer, allocator);

    return result;
}

pub fn fetch_image(self: *@This(), writer: *std.Io.Writer, allocator: Allocator, url: []const u8, opts: FetchHeaderOptions) !?CacheControl {
    var resp = try self.fetch_image_response(url, opts);
    const re = try handle_image_response(&resp, writer, allocator);
    return re;
}

pub fn fetch_image_response(self: *@This(), url: []const u8, opts: FetchHeaderOptions) !http.Client.Response {
    const uri = try std.Uri.parse(url);
    var extra_headers_arr: [2]std.http.Header = undefined;
    extra_headers_arr[0] = .{ .name = "Accept", .value = "image/*" };

    var request_opts: std.http.Client.RequestOptions = .{
        .keep_alive = false,
        .redirect_behavior = .init(5),
        .extra_headers = extra_headers_arr[0..1],
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
        extra_headers_arr[1] = h;

        request_opts.extra_headers = &extra_headers_arr;
    }

    self.request = try self.client.request(.GET, uri, request_opts);
    errdefer self.request.?.deinit();

    try self.request.?.sendBodiless();

    self.response = try self.request.?.receiveHead(opts.buffer_header);
    
    return self.response.?;
}

pub fn resp_to_icon_body(body: []const u8, url: []const u8) ?[]const u8 {
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

pub fn get_uri(self: *const @This()) !Uri {
    return self.request.?.uri;
}

pub fn get_url_slice(self: *const @This(), buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{f}", .{self.request.?.uri});
}

pub fn fill_headers(bytes: []const u8, map: *HeaderMap, keys: []const []const u8) !void {
    var iter = mem.splitSequence(u8, bytes, "\r\n");
    _ = iter.first();

    while (iter.next()) |line| {
        if (line.len == 0) return;
        switch (line[0]) {
            ' ', '\t' => return error.HttpHeaderContinuationsUnsupported,
            else => {},
        }

        var line_it = mem.splitScalar(u8, line, ':');
        const header_name = line_it.next().?;
        const header_value = mem.trim(u8, line_it.rest(), " \t");
        if (header_name.len == 0) return error.HttpHeadersInvalid;

        for (keys) |key| {
            if (std.ascii.eqlIgnoreCase(key, header_name)) {
                map.putAssumeCapacity(key, header_value);
                break;
            }
        }
    }
}
