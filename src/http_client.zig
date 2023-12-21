const std = @import("std");
const datetime = @import("zig-datetime").datetime;
const feed_types = @import("./feed_types.zig");
const ContentType = feed_types.ContentType;
const RssDateTime = feed_types.RssDateTime;
const FetchHeaderOptions = feed_types.FetchHeaderOptions;
const http = std.http;
const mem = std.mem;
const print = std.debug.print;
const Client = http.Client;
const Allocator = mem.Allocator;
const Request = http.Client.Request;
const Response = http.Client.Response;
const Uri = std.Uri;
const assert = std.debug.assert;

pub const HeaderValues = struct {
    content_type: ?ContentType = null,
    etag: ?[]const u8 = null,
    last_modified: ?i64 = null,
    expires: ?i64 = null,
    max_age: ?u32 = null,

    pub fn fromRawHeader(input: []const u8) HeaderValues {
        const etag_key = "etag:";
        const content_type_key = "content-type:";
        const last_modified_key = "last-modified:";
        const expires_key = "expires:";
        const cache_control_key = "cache-control:";

        var result: HeaderValues = .{};
        var iter = std.mem.split(u8, input, "\r\n");
        _ = iter.first();
        while (iter.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, etag_key)) {
                result.etag = std.mem.trim(u8, line[etag_key.len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, content_type_key)) {
                result.content_type = ContentType.fromString(std.mem.trim(u8, line[content_type_key.len..], " "));
            } else if (std.ascii.startsWithIgnoreCase(line, last_modified_key)) {
                const raw = std.mem.trim(u8, line[last_modified_key.len..], " ");
                result.last_modified = RssDateTime.parse(raw) catch null;
            } else if (std.ascii.startsWithIgnoreCase(line, expires_key)) {
                const raw = std.mem.trim(u8, line[expires_key.len..], " ");
                result.expires = RssDateTime.parse(raw) catch null;
            } else if (std.ascii.startsWithIgnoreCase(line, cache_control_key)) {
                var key_value_iter = std.mem.split(u8, line[cache_control_key.len..], ",");
                while (key_value_iter.next()) |key_value| {
                    var pair_iter = mem.split(u8, key_value, "=");
                    const key = pair_iter.next() orelse continue;
                    const value = pair_iter.next() orelse continue;
                    if (mem.eql(u8, "max-age", key)) {
                        result.max_age = std.fmt.parseUnsigned(u32, value, 10) catch continue;
                        break;
                    } else if (mem.eql(u8, "s-maxage", value)) {
                        result.max_age = std.fmt.parseUnsigned(u32, value, 10) catch continue;
                    }
                }
            }
        }
        return result;
    }
};

pub fn createHeaders(allocator: Allocator, opts: FetchHeaderOptions) !http.Headers {
    var headers = http.Headers.init(allocator);
    try headers.append("Accept", "application/atom+xml, application/rss+xml, text/xml, application/xml, text/html");
    if (opts.etag) |etag| {
        try headers.append("If-Match", etag);
    }
    var date_buf: [29]u8 = undefined;
    if (opts.last_modified_utc) |utc| {
        const date_slice = try datetime.Datetime.formatHttpFromTimestamp(&date_buf, utc);
        try headers.append("If-Modified-Since", date_slice);
    }
    return headers;
}

allocator: Allocator,
headers: http.Headers,
client: http.Client,

pub fn init(allocator: Allocator, headers_opts: FetchHeaderOptions) !@This() {
    return .{
        .allocator = allocator,
        .headers = try createHeaders(allocator, headers_opts),
        .client = Client{ .allocator = allocator },
    };
}

pub fn deinit(self: *@This()) void {
    self.headers.deinit();
    self.client.deinit();
}

pub fn fetch(self: *@This(), url: []const u8) !http.Client.FetchResult {
    const options = .{
        .location = .{.url = url},
        .headers = self.headers,
    };
    return try http.Client.fetch(&self.client, self.allocator, options);
}
