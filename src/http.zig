const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const l = std.log;
const gzip = std.compress.gzip;
const hzzp = @import("hzzp");
const FixedBufferStream = std.io.FixedBufferStream;
const client = hzzp.base.client;
const Headers = hzzp.Headers;
const bearssl = @import("zig-bearssl");
const dateStrToTimeStamp = @import("rss.zig").pubDateToTimestamp;

// NOTE: http header can conatain three valid datetime formats.
// There is prefered one and 2 obsolete ones. Only use prefered one at the moment.
// Use datetime function that wrote for RSS spec datetime format.
// Http date spec: https://tools.ietf.org/html/rfc7231#section-7.1.1.1

// Caching
// https://www.ctrl.blog/entry/feed-caching.html
// https://www.keycdn.com/blog/http-cache-headers
//
// TODO: resolve redirects
// TODO: Build (exsiting) feed's request header
// This doesn't take into account rss update values.
// Cache-Control and Etag are modern
//
// Cache-Control (use over Expires):
// 	max-age
// 	s-maxage - overrides max-age and Expires
// Expires
//
// Etag + If-None-Match (take priority over If-Modified-Since)
//  'If-None-Match' on GET will return only header values (no body)
// Last-Modified + If-Modified-Since
//  'If-Modified-Since' works like 'If-None-Match'
//
// If feed has if-none-match or if-modified-since use GET method
// 	Status code '304 Not Modified'

const FeedResponse = struct {
    url: Url,
    cache_control_max_age: ?usize = null, // s-maxage or max-age, if available ignore expires
    expires_utc: ?i64 = null,
    // Owns the memory
    etag: ?[]const u8 = null,
    last_modified_utc: ?i64 = null,
    // Owns the memory
    body: ?[]const u8 = null,
    // TODO: content_type: <enum>,
};

const Encoding = enum {
    none,
    gzip,
    deflate,
};

pub fn httpsRequest(allocator: *Allocator, url: []const u8) !FeedResponse {
    const cert = @embedFile("../mozilla_certs.pem");
    const u = try makeUrl(url);
    const host = try std.cstr.addNullByte(allocator, u.domain);
    defer allocator.free(host);
    const port = 443;
    const path = u.path;

    var feed_resp = FeedResponse{
        .url = u,
    };

    const tcp_conn = try std.net.tcpConnectToHost(allocator, host, port);
    defer tcp_conn.close();

    var tcp_reader = tcp_conn.reader();
    var tcp_writer = tcp_conn.writer();

    var trust_anchor = bearssl.TrustAnchorCollection.init(allocator);
    defer trust_anchor.deinit();
    try trust_anchor.appendFromPEM(cert);

    var x509 = bearssl.x509.Minimal.init(trust_anchor);
    var ssl_client = bearssl.Client.init(x509.getEngine());
    ssl_client.relocate();
    try ssl_client.reset(host, false);

    var ssl_stream = bearssl.initStream(
        ssl_client.getEngine(),
        &tcp_reader,
        &tcp_writer,
    );

    var ssl_reader = ssl_stream.inStream();
    var ssl_writer = ssl_stream.outStream();

    var client_reader = ssl_reader;
    var client_writer = ssl_writer;

    // TODO: figure out header buffer (size)
    var request_buf: [60 * 1024]u8 = undefined;
    var head_client = client.create(&request_buf, client_reader, client_writer);

    try head_client.writeStatusLine("GET", path);
    try head_client.writeHeaderValue("Accept-Encoding", "gzip");
    try head_client.writeHeaderValue("Connection", "close");
    try head_client.writeHeaderValue("Host", host);
    try head_client.writeHeaderValue("Accept", "application/rss+xml, text/xml, application/atom+xml");
    try head_client.finishHeaders();
    try ssl_stream.flush();

    var content_encoding = Encoding.none;

    var content_len: usize = 0;

    while (try head_client.next()) |event| {
        switch (event) {
            .status => |status| {
                std.debug.print("<HTTP Status {}>\n", .{status.code});
                if (status.code != 200 and status.code != 304) {
                    return error.InvalidStatusCode;
                }
            },
            .header => |header| {
                if (ascii.eqlIgnoreCase("cache-control", header.name)) {
                    var it = mem.split(header.value, ",");
                    while (it.next()) |v_raw| {
                        const v = mem.trimLeft(u8, v_raw, " \r\n\t");
                        if (feed_resp.cache_control_max_age == null and
                            ascii.startsWithIgnoreCase(v, "max-age"))
                        {
                            const eq_index = mem.indexOfScalar(u8, v, '=') orelse continue;
                            const nr = v[eq_index + 1 ..];
                            feed_resp.cache_control_max_age =
                                try std.fmt.parseInt(usize, nr, 10);
                        } else if (ascii.startsWithIgnoreCase(v, "s-maxage")) {
                            const eq_index = mem.indexOfScalar(u8, v, '=') orelse continue;
                            const nr = v[eq_index + 1 ..];
                            feed_resp.cache_control_max_age =
                                try std.fmt.parseInt(usize, nr, 10);
                        }
                    }
                } else if (ascii.eqlIgnoreCase("etag", header.name)) {
                    feed_resp.etag = try allocator.dupe(u8, header.value);
                    errdefer allocator.free(feed_resp.etag);
                } else if (ascii.eqlIgnoreCase("last-modified", header.name)) {
                    feed_resp.last_modified_utc = try dateStrToTimeStamp(header.value);
                } else if (ascii.eqlIgnoreCase("expires", header.name)) {
                    feed_resp.expires_utc = try dateStrToTimeStamp(header.value);
                } else if (ascii.eqlIgnoreCase("content-length", header.name)) {
                    const body_len = try std.fmt.parseInt(usize, header.value, 10);
                    content_len = body_len;
                } else if (ascii.eqlIgnoreCase("content-encoding", header.name)) {
                    var it = mem.split(header.value, ",");
                    while (it.next()) |val_raw| {
                        // TODO: content can be compressed multiple times
                        // Content-Type: gzip, deflate
                        const val = mem.trimLeft(u8, val_raw, " \r\n\t");
                        if (ascii.startsWithIgnoreCase(val, "gzip")) {
                            content_encoding = .gzip;
                        } else if (ascii.startsWithIgnoreCase(val, "deflate")) {
                            content_encoding = .deflate;
                        }
                    }
                }
                std.debug.print("{s}: {s}\n", .{ header.name, header.value });
            },
            .head_done => {
                std.debug.print("---\n", .{});
                break;
            },
            .skip => {},
            .payload => unreachable,
            .end => std.debug.print("<empty body>", .{}),
        }
    }

    switch (content_encoding) {
        .none => {
            l.warn("No compression", .{});
            var body = try ssl_reader.readAllAlloc(allocator, content_len);
            errdefer allocator.free(body);
            feed_resp.body = body;
        },
        .gzip => {
            l.warn("Decompressin gzip", .{});
            var compress = try gzip.gzipStream(allocator, client_reader);
            defer compress.deinit();
            var reader = compress.reader();

            var body = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
            errdefer allocator.free(body);
            feed_resp.body = body;
        },
        .deflate => @panic("TODO: deflate decompress"),
    }

    return feed_resp;
}

test "download" {
    const cert = @embedFile("../mozilla_certs.pem");
    var allocator = std.testing.allocator;
    // {
    // const input = "https://lobste.rs/";
    // const resp = try httpsRequest(allocator, input);
    // std.debug.warn("{}\n", .{resp});
    // }
    {
        const input = "https://news.xbox.com/en-us/feed/";
        const resp = try httpsRequest(allocator, input);
        defer {
            if (resp.body) |body| allocator.free(body);
            if (resp.etag) |etag| allocator.free(etag);
        }
        l.warn("{s}\n", .{resp.etag});
        std.debug.warn("{s}\n", .{resp.body.?[0..200]});
    }
}

const Url = struct {
    domain: []const u8,
    path: []const u8,
};

// https://www.whogohost.com/host/knowledgebase/308/Valid-Domain-Name-Characters.html
// https://stackoverflow.com/a/53875771
// NOTE: will error with urls that contain port
pub fn makeUrl(url_str: []const u8) !Url {
    // Actually url.len must atleast be 10 or there abouts
    const url = blk: {
        if (mem.eql(u8, "http", url_str[0..4])) {
            var it = mem.split(url_str, "://");
            // protocol
            _ = it.next() orelse return error.InvalidUrl;
            break :blk it.rest();
        }
        break :blk url_str;
    };

    const slash_index = mem.indexOfScalar(u8, url, '/') orelse url.len;
    const domain_all = url[0..slash_index];
    const dot_index = mem.lastIndexOfScalar(u8, domain_all, '.') orelse return error.InvalidDomain;
    const domain = domain_all[0..dot_index];
    const domain_ext = domain_all[dot_index + 1 ..];

    if (!ascii.isAlNum(domain[0])) return error.InvalidDomain;
    if (!ascii.isAlNum(domain[domain.len - 1])) return error.InvalidDomain;
    if (!ascii.isAlpha(domain_ext[0])) return error.InvalidDomainExtension;

    const domain_rest = domain[1 .. domain.len - 2];
    const domain_ext_rest = domain_ext[1..];

    for (domain_rest) |char| {
        if (!ascii.isAlNum(char) and char != '-' and char != '.') {
            return error.InvalidDomain;
        }
    }

    for (domain_ext_rest) |char| {
        if (!ascii.isAlNum(char) and char != '-') {
            return error.InvalidDomainExtension;
        }
    }

    const path = if (url[slash_index..].len == 0) "/" else url[slash_index..];
    return Url{
        .domain = domain_all,
        .path = path,
    };
}

// test "url" {
//     {
//         const input = "https://news.xbox.com";
//         // const url = "https://news.xbox.com/en-us/feed/";
//         const url = try makeUrl(input);
//         std.testing.expectEqualStrings("news.xbox.com", url.domain);
//         std.testing.expectEqualStrings("/", url.path);
//     }

//     {
//         const input = "https://news.xbox.com/en-us/feed/";
//         const url = try makeUrl(input);
//         std.testing.expectEqualStrings("news.xbox.com", url.domain);
//         std.testing.expectEqualStrings("/en-us/feed/", url.path);
//     }

//     {
//         const input = "news.xbox.com/en-us/feed/";
//         const url = try makeUrl(input);
//         std.testing.expectEqualStrings("news.xbox.com", url.domain);
//         std.testing.expectEqualStrings("/en-us/feed/", url.path);
//     }
// }
