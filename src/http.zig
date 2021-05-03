const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const bearssl = @import("zig-bearssl");
const Uri = @import("zuri").Uri;
const gzip = std.compress.gzip;
const hzzp = @import("hzzp");
const client = hzzp.base.client;
const Headers = hzzp.Headers;
const l = std.log;
const dateStrToTimeStamp = @import("parse.zig").Rss.pubDateToTimestamp;
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

pub const FeedResponse = struct {
    url: Uri,
    cache_control_max_age: ?usize = null, // s-maxage or max-age, if available ignore expires
    expires_utc: ?i64 = null,
    // Owns the memory
    etag: ?[]const u8 = null,
    last_modified_utc: ?i64 = null,
    content_type: ContentType = .unknown,
    // Owns the memory
    body: ?[]const u8 = null,
    location: ?[]const u8 = null,
    status_code: u16 = 0,
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
    unknown,
    xml,
    xml_atom,
    xml_rss,
    html,
};

pub fn resolveRequest(allocator: *Allocator, req: FeedRequest) !FeedResponse {
    var resp = try makeRequest(allocator, req);
    while (resp.location) |location| {
        l.warn("REDIRECTING TO {s}", .{location});
        const new_req = FeedRequest{ .url = try Uri.parse(location, false) };
        resp = try makeRequest(allocator, new_req);
    }
    return resp;
}

pub fn makeRequest(allocator: *Allocator, req: FeedRequest) !FeedResponse {
    const cert = @embedFile("../mozilla_certs.pem");
    const host = try std.cstr.addNullByte(allocator, req.url.host.name);
    defer allocator.free(host);
    const port = 443;
    const path = req.url.path;

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

    var ssl_reader = ssl_stream.reader();
    var ssl_writer = ssl_stream.writer();

    var client_reader = ssl_reader;
    var client_writer = ssl_writer;

    var request_buf: [std.mem.page_size * 2]u8 = undefined;
    var head_client = client.create(&request_buf, client_reader, client_writer);

    try head_client.writeStatusLine("GET", path);
    try head_client.writeHeaderValue("Accept-Encoding", "gzip");
    try head_client.writeHeaderValue("Connection", "close");
    try head_client.writeHeaderValue("Host", host);
    try head_client.writeHeaderValue("Accept", "application/rss+xml, application/atom+xml, text/xml, application/xml, text/html");
    if (req.etag) |etag| {
        try head_client.writeHeaderValue("If-None-Match", etag);
    } else if (req.last_modified) |time| {
        try head_client.writeHeaderValue("If-Modified-Since", time);
    }
    try head_client.finishHeaders();
    try ssl_stream.flush();

    var content_encoding = ContentEncoding.none;
    var transfer_encoding = TransferEncoding.none;

    var content_len: usize = std.math.maxInt(usize);

    var status_code: u16 = 0;
    var feed_resp = FeedResponse{ .url = req.url };

    while (try head_client.next()) |event| {
        switch (event) {
            .status => |status| {
                // l.warn("HTTP status code: {}", .{status.code});
                feed_resp.status_code = status.code;
                if (status.code == 304) {
                    return feed_resp;
                } else if (status.code == 301 or status.code == 302) {
                    status_code = status.code;
                } else if (status.code != 200) {
                    l.err("HTTP status code {d} not handled", .{status.code});
                    return error.InvalidStatusCode;
                }
            },
            .header => |header| {
                // std.debug.print("{s}: {s}\n", .{ header.name, header.value });
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
                                try fmt.parseInt(usize, nr, 10);
                        } else if (ascii.startsWithIgnoreCase(v, "s-maxage")) {
                            const eq_index = mem.indexOfScalar(u8, v, '=') orelse continue;
                            const nr = v[eq_index + 1 ..];
                            feed_resp.cache_control_max_age =
                                try fmt.parseInt(usize, nr, 10);
                        }
                    }
                } else if (ascii.eqlIgnoreCase("etag", header.name)) {
                    feed_resp.etag = try allocator.dupe(u8, header.value);
                    errdefer allocator.free(feed_resp.etag);
                } else if (ascii.eqlIgnoreCase("last-modified", header.name)) {
                    feed_resp.last_modified_utc = try dateStrToTimeStamp(header.value);
                } else if (ascii.eqlIgnoreCase("expires", header.name)) {
                    feed_resp.expires_utc = dateStrToTimeStamp(header.value) catch |_| {
                        continue;
                    };
                } else if (ascii.eqlIgnoreCase("content-length", header.name)) {
                    const body_len = try fmt.parseInt(usize, header.value, 10);
                    content_len = body_len;
                } else if (ascii.eqlIgnoreCase("content-type", header.name)) {
                    const len = mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
                    const value = header.value[0..len];
                    if (ascii.eqlIgnoreCase("text/html", value)) {
                        feed_resp.content_type = .html;
                    } else if (ascii.eqlIgnoreCase("application/rss+xml", value)) {
                        feed_resp.content_type = .xml_rss;
                    } else if (ascii.eqlIgnoreCase("application/atom+xml", value)) {
                        feed_resp.content_type = .xml_atom;
                    } else if (ascii.eqlIgnoreCase("application/xml", value) or
                        ascii.eqlIgnoreCase("text/xml", value))
                    {
                        feed_resp.content_type = .xml;
                    }
                } else if (ascii.eqlIgnoreCase("transfer-encoding", header.name)) {
                    if (ascii.eqlIgnoreCase("chunked", header.value)) {
                        transfer_encoding = .chunked;
                    }
                } else if (ascii.eqlIgnoreCase("location", header.name)) {
                    feed_resp.location = try allocator.dupe(u8, header.value);
                    errdefer allocator.free(feed_resp.location);
                } else if (ascii.eqlIgnoreCase("content-encoding", header.name)) {
                    var it = mem.split(header.value, ",");
                    while (it.next()) |val_raw| {
                        const val = mem.trimLeft(u8, val_raw, " \r\n\t");
                        if (ascii.startsWithIgnoreCase(val, "gzip")) {
                            content_encoding = .gzip;
                        }
                    }
                }
            },
            .head_done => {
                std.debug.print("---\n", .{});
                if (status_code == 301) {
                    return feed_resp;
                }
                break;
            },
            .skip => {},
            .payload => unreachable,
            // .payload => |payload| {
            //     l.warn("{s}", .{payload});
            // },
            .end => {
                std.debug.print("<empty body>\nNothing to parse\n", .{});
                return feed_resp;
            },
        }
    }

    switch (transfer_encoding) {
        .none => {
            // l.warn("Body response", .{});
            switch (content_encoding) {
                .none => {
                    // l.warn("No compression", .{});

                    if (content_len == std.math.maxInt(usize)) return error.NoContentLength;

                    var array_list = std.ArrayList(u8).init(allocator);
                    defer array_list.deinit();
                    try array_list.resize(content_len);
                    var read_index: usize = 0;
                    while (true) {
                        const bytes = try client_reader.read(array_list.items[read_index..]);
                        read_index += bytes;
                        if (read_index == content_len) break;
                    }

                    feed_resp.body = array_list.toOwnedSlice();
                },
                .gzip => {
                    // l.warn("Decompress gzip", .{});

                    // TODO: might have redo it like .none part
                    var stream = try gzip.gzipStream(allocator, client_reader);
                    defer stream.deinit();

                    feed_resp.body = try stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
                },
            }
        },
        .chunked => {
            // l.warn("Chunked response", .{});
            var output = ArrayList(u8).init(allocator);
            errdefer output.deinit();

            switch (content_encoding) {
                .none => {
                    // l.warn("No compression", .{});
                    while (true) {
                        const hex_str = try client_reader.readUntilDelimiterOrEof(&request_buf, '\r');
                        if (hex_str == null) return error.InvalidChunk;
                        if ((try client_reader.readByte()) != '\n') return error.InvalidChunk;

                        var chunk_len = try fmt.parseUnsigned(usize, hex_str.?[0..], 16);
                        if (chunk_len == 0) break;
                        try output.ensureCapacity(output.items.len + chunk_len);
                        while (chunk_len > 0) {
                            const read_size = if (chunk_len > request_buf.len)
                                request_buf.len
                            else
                                chunk_len;
                            const size = try client_reader.read(request_buf[0..read_size]);
                            chunk_len -= size;
                            output.appendSliceAssumeCapacity(request_buf[0..size]);
                        }
                        if ((try client_reader.readByte()) != '\r' or
                            (try client_reader.readByte()) != '\n') return error.InvalidChunk;
                    }

                    feed_resp.body = output.toOwnedSlice();
                },
                .gzip => {
                    // l.warn("Decompress gzip", .{});

                    while (true) {
                        const hex_str = try client_reader.readUntilDelimiterOrEof(&request_buf, '\r');
                        if (hex_str == null) return error.InvalidChunk;
                        if ((try client_reader.readByte()) != '\n') return error.InvalidChunk;

                        var chunk_len = try fmt.parseUnsigned(usize, hex_str.?[0..], 16);
                        if (chunk_len == 0) break;
                        try output.ensureCapacity(output.items.len + chunk_len);
                        while (chunk_len > 0) {
                            const read_size = if (chunk_len > request_buf.len)
                                request_buf.len
                            else
                                chunk_len;
                            const size = try client_reader.read(request_buf[0..read_size]);
                            chunk_len -= size;
                            try output.appendSlice(request_buf[0..size]);
                        }
                        if ((try client_reader.readByte()) != '\r' or
                            (try client_reader.readByte()) != '\n') return error.InvalidChunk;
                    }

                    const gzip_buf = std.io.fixedBufferStream(output.toOwnedSlice()).reader();

                    var stream = try gzip.gzipStream(allocator, gzip_buf);
                    defer stream.deinit();
                    const gzip_reader = stream.reader();

                    var body = try gzip_reader.readAllAlloc(allocator, std.math.maxInt(usize));
                    errdefer allocator.free(body);

                    feed_resp.body = body;
                },
            }
        },
    }

    return feed_resp;
}

pub const Url = struct {
    protocol: []const u8,
    domain: []const u8,
    path: []const u8,
};

// https://www.whogohost.com/host/knowledgebase/308/Valid-Domain-Name-Characters.html
// https://stackoverflow.com/a/53875771
// NOTE: urls with port will error
// NOTE: https://localhost will error
pub fn makeUrl(url_str: []const u8) !Url {
    var result: Url = undefined;
    result.protocol = "http";
    var url = url_str;
    if (mem.indexOf(u8, url_str, "://")) |index| {
        result.protocol = url_str[0..index];
        url = url_str[index + 3 ..];
    }

    const slash_index = mem.indexOfScalar(u8, url, '/') orelse url.len;
    result.domain = url[0..slash_index];
    result.path = if (slash_index == url.len) "/" else url[slash_index..];

    return result;
}

test "makeUrl" {
    {
        const url = try makeUrl("https://google.com/");
        expect(mem.eql(u8, url.protocol, "https"));
        expect(mem.eql(u8, url.domain, "google.com"));
        expect(mem.eql(u8, url.path, "/"));
    }

    {
        const url = try makeUrl("google.com");
        expect(mem.eql(u8, url.protocol, "http"));
        expect(mem.eql(u8, url.domain, "google.com"));
        expect(mem.eql(u8, url.path, "/"));
    }

    {
        const url = try makeUrl("google.com/test/path");
        expect(mem.eql(u8, url.protocol, "http"));
        expect(mem.eql(u8, url.domain, "google.com"));
        expect(mem.eql(u8, url.path, "/test/path"));
    }
}

test "http" {
    const testing = std.testing;
    const rand = std.rand;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const url = makeUrl("http://google.com/") catch unreachable;
    // const url = makeUrl("http://lobste.rs") catch unreachable;
    // const url = makeUrl("https://www.aruba.it/CMSPages/GetResource.ashx?scriptfile=%2fCMSScripts%2fCustom%2faruba.js") catch unreachable; // chunked + deflate
    // const url = makeUrl("https://news.xbox.com/en-us/feed/") catch unreachable;
    // const url = makeUrl("https://feeds.feedburner.com/eclipse/fnews") catch unreachable;

    // var r = rand.DefaultPrng.init(@intCast(u64, std.time.milliTimestamp()));
    // l.warn("rand: {}", .{r.random.int(u8)});

    const req = FeedRequest{ .url = url };
    const resp = try resolveRequest(allocator, req);
}
