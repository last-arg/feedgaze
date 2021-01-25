const std = @import("std");
const sql = @import("sqlite");
const datetime = @import("datetime");
const Datetime = datetime.Datetime;
const ascii = std.ascii;
const timezones = datetime.timezones;
const rss = @import("rss.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const process = std.process;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const bearssl = @import("zig-bearssl");
const gzip = std.compress.gzip;
const hzzp = @import("hzzp");
const client = hzzp.base.client;
const Headers = hzzp.Headers;
const l = std.log;
usingnamespace @import("queries.zig");

pub const log_level = std.log.Level.info;

// Sqlite
// Do upsert with update and insert:
// https://stackoverflow.com/questions/15277373/sqlite-upsert-update-or-insert/38463024#38463024
// TODO: find domain's rss feeds
// 		html link application+xml
// 		for popular platforms can guess url. wordpress: /feed/
// TODO?: PRAGMA schema.user_version = integer ;
// TODO: implement downloading a file
// TODO: see if there is good way to detect local file path or url

const default_db_location = "./tmp/test.db";
pub fn main() anyerror!void {
    std.log.info("Main run", .{});
    const base_allocator = std.heap.page_allocator;
    // const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const abs_location = try makeFilePath(allocator, default_db_location);
    const db_file = try std.fs.createFileAbsolute(
        abs_location,
        .{ .read = true, .truncate = false },
    );

    // TODO: replace memory db with file db
    var db = try memoryDb();
    try dbSetup(&db);

    var iter = process.args();
    _ = iter.skip();

    while (iter.next(allocator)) |arg_err| {
        const arg = try arg_err;
        if (mem.eql(u8, "add", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try cliAddFeed(&db, allocator, value);
            } else {
                l.err("Subcommand add missing feed location", .{});
            }
            if (mem.eql(u8, "update", arg)) {
                const ids = try updateFeeds(allocator, &db);
                // TODO: check for updates
            } else {
                return error.UnknownArgument;
            }
        }
        try printAllItems(&db, allocator);
    }
}

test "does feed need update" {
    const input = "./test/sample-rss-2.xml";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    var db = try memoryDb();
    try dbSetup(&db);

    try cliAddFeed(&db, allocator, input);

    try updateFeeds(allocator, &db);
}

pub fn updateFeeds(allocator: *Allocator, db: *sql.Db) !void {
    @setEvalBranchQuota(2000);

    const DbResult = struct {
        location: []const u8,
        etag: ?[]const u8,
        feed_id: usize,
        update_interval: usize,
        ttl: ?usize,
        last_update: i64,
        expires_utc: ?i64,
        last_modified_utc: ?i64,
        cache_control_max_age: ?i64,
        pub_date_utc: ?i64,
        last_build_date_utc: ?i64,
    };

    const feed_updates = try selectAll(DbResult, allocator, db, Table.feed_update.selectAllWithLocation, .{});
    var indexes = try ArrayList(usize).initCapacity(allocator, feed_updates.len);

    const current_time = std.time.timestamp();

    for (feed_updates) |obj, i| {
        l.warn("{}", .{obj.pub_date_utc});
        const check_date: i64 = blk: {
            if (obj.ttl) |min| {
                // Uses ttl, last_build_date_utc || last_update
                const base_date = if (obj.last_build_date_utc) |d| d else obj.last_update;
                break :blk base_date + (std.time.s_per_min * @intCast(i64, min));
            } else if (obj.cache_control_max_age) |sec| {
                // Uses cache_control_max_age, last_update
                break :blk obj.last_update + sec;
            }
            break :blk obj.last_update + @intCast(i64, obj.update_interval);
        };

        if (obj.expires_utc) |expire| {
            if (check_date < expire) {
                continue;
            }
        } else if (check_date < current_time) {
            continue;
        }

        try indexes.append(i);
    }

    // Set all feed_update rows last_update to datetime now
    try update(db, Table.feed_update.update_all, .{});

    for (indexes.items) |i| {
        const obj = feed_updates[i];
        // const url_or_err = Http.makeUrl(obj.location);
        // const url_or_err = Http.makeUrl("https://lobste.rs");
        // const url_or_err = Http.makeUrl("https://news.xbox.com/en-us/feed/");
        const url_or_err = Http.makeUrl("https://feeds.feedburner.com/eclipse/fnews");

        if (url_or_err) |url| {
            l.warn("Feed's HTTP request", .{});
            var req = Http.FeedRequest{ .url = url };
            // optional:
            if (obj.etag) |etag| {
                // If-None-Match: etag
                req.etag = etag;
            } else if (obj.last_modified_utc) |last_modified_utc| {
                // If-Modified-Since
                const date = Datetime.fromTimestamp(last_modified_utc);
                var date_buf: [29]u8 = undefined;
                const date_fmt = "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT";
                const date_str = try std.fmt.bufPrint(&date_buf, date_fmt, .{
                    date.date.weekdayName()[0..3],
                    date.date.day,
                    date.date.monthName()[0..3],
                    date.date.year,
                    date.time.hour,
                    date.time.minute,
                    date.time.second,
                });
                req.last_modified_utc = date_str;
            }

            const resp = try Http.makeRequest(allocator, req);
            if (resp.body) |b| {
                l.warn("#len: {}#", .{b.len});
                l.warn("#len: {s}#", .{b[0..100]});
            }

            // No new content if body is null
            if (resp.body == null) continue;

            const body = resp.body.?;

            const rss_feed = try rss.Feed.init(allocator, "this_url", body);
            try update(db, Table.feed_update.update_id, .{
                rss_feed.info.ttl,
                resp.cache_control_max_age,
                resp.expires_utc,
                resp.last_modified_utc,
                resp.etag,
                // where
                obj.feed_id,
            });

            const has_changed = rss_feed.info.pub_date_utc == null or
                !std.meta.eql(obj.pub_date_utc, rss_feed.info.pub_date_utc) or
                !std.meta.eql(obj.last_build_date_utc, rss_feed.info.last_build_date_utc);

            if (has_changed) {
                // feed update
                try update(db, Table.feed.update_id, .{
                    rss_feed.info.title,
                    rss_feed.info.link,
                    rss_feed.info.pub_date,
                    rss_feed.info.pub_date_utc,
                    rss_feed.info.last_build_date,
                    rss_feed.info.last_build_date_utc,
                    // where
                    obj.feed_id,
                });

                // add items: get newest feed's item pub_date
                const latest_item_date = try one(
                    i64,
                    db,
                    Table.item.select_feed_latest,
                    .{obj.feed_id},
                );

                if (latest_item_date) |latest_date| {
                    const len = blk: {
                        for (rss_feed.items) |item, idx| {
                            if (item.pub_date_utc) |item_date| {
                                if (item_date <= latest_date) {
                                    break :blk idx;
                                }
                            }
                        }
                        break :blk 0;
                    };
                    if (len > 0) {
                        try addFeedItems(db, rss_feed.items[0..len], obj.feed_id);
                    }
                } else {
                    try addFeedItems(db, rss_feed.items, obj.feed_id);
                }
            }
        } else |_| {
            l.warn("Check local file feed", .{});
            // TODO?: file's last_modified date
            const contents = getLocalFileContents(allocator, obj.location) catch |err| switch (err) {
                std.fs.File.OpenError.FileNotFound => {
                    l.err("Could not locate local feed (file) at: '{}'", .{obj.location});
                    continue;
                },
                else => return err,
            };
            defer allocator.free(contents);

            var feed = try rss.Feed.init(allocator, obj.location, contents);
            defer feed.deinit();
            const need_update = feed.info.pub_date_utc == null or
                !std.meta.eql(feed.info.pub_date_utc, obj.pub_date_utc);
            if (need_update) {
                l.warn("Update local feed", .{});
                try update(db, Table.feed.update_id, .{
                    feed.info.title,
                    feed.info.link,
                    feed.info.pub_date,
                    feed.info.pub_date_utc,
                    feed.info.last_build_date,
                    feed.info.last_build_date_utc,
                    // where
                    obj.feed_id,
                });

                try addFeedItems(db, feed.items, obj.feed_id);
            }
        }
    }
}

const Http = struct {
    const dateStrToTimeStamp = @import("rss.zig").pubDateToTimestamp;
    const FeedRequest = struct {
        url: Url,
        etag: ?[]const u8 = null,
        last_modified_utc: ?[]const u8 = null,
    };

    const FeedResponse = struct {
        cache_control_max_age: ?usize = null, // s-maxage or max-age, if available ignore expires
        expires_utc: ?i64 = null,
        // Owns the memory
        etag: ?[]const u8 = null,
        last_modified_utc: ?i64 = null,
        // Owns the memory
        body: ?[]const u8 = null,
        // TODO: content_type: <enum>,
    };

    const ContentEncoding = enum {
        none,
        gzip,
        deflate,
    };

    const TransferEncoding = enum {
        none,
        chunked,
    };

    pub fn makeRequest(allocator: *Allocator, req: FeedRequest) !FeedResponse {
        const cert = @embedFile("../mozilla_certs.pem");
        const host = try std.cstr.addNullByte(allocator, req.url.domain);
        defer allocator.free(host);
        const port = 443;
        const path = req.url.path;

        var feed_resp = FeedResponse{};

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

        var request_buf: [std.mem.page_size]u8 = undefined;
        var head_client = client.create(&request_buf, client_reader, client_writer);

        try head_client.writeStatusLine("GET", path);
        // TODO: etag and last-modified
        // try head_client.writeHeaderValue("Accept-Encoding", "gzip, deflate");
        try head_client.writeHeaderValue("Connection", "close");
        try head_client.writeHeaderValue("Host", host);
        try head_client.writeHeaderValue("Accept", "application/rss+xml, application/atom+xml, text/xml");
        try head_client.finishHeaders();
        try ssl_stream.flush();

        var content_encoding = ContentEncoding.none;
        var transfer_encoding = TransferEncoding.none;

        var content_len: usize = std.math.maxInt(usize);

        while (try head_client.next()) |event| {
            switch (event) {
                .status => |status| {
                    std.debug.print("<HTTP Status {}>\n", .{status.code});
                    if (status.code == 304) {
                        return feed_resp;
                    } else if (status.code != 200) {
                        return error.InvalidStatusCode;
                    }
                },
                .header => |header| {
                    std.debug.print("{s}: {s}\n", .{ header.name, header.value });
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
                    } else if (ascii.eqlIgnoreCase("expires", header.name) and
                        !mem.eql(u8, "0", header.value))
                    {
                        feed_resp.expires_utc = try dateStrToTimeStamp(header.value);
                    } else if (ascii.eqlIgnoreCase("content-length", header.name)) {
                        const body_len = try std.fmt.parseInt(usize, header.value, 10);
                        content_len = body_len;
                    } else if (ascii.eqlIgnoreCase("transfer-encoding", header.name)) {
                        if (ascii.eqlIgnoreCase("chunked", header.value)) {
                            transfer_encoding = .chunked;
                        }
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
                },
                .head_done => {
                    std.debug.print("---\n", .{});
                    break;
                },
                .skip => {},
                .payload => unreachable,
                .end => {
                    std.debug.print("<empty body>\nNothing to parse\n", .{});
                    return feed_resp;
                },
            }
        }

        switch (transfer_encoding) {
            .none => {
                l.warn("Transfer encoding none", .{});
                const len = std.math.maxInt(usize);
                switch (content_encoding) {
                    .none => {
                        l.warn("No compression", .{});
                        feed_resp.body = try client_reader.readAllAlloc(allocator, len);
                    },
                    .gzip => {
                        l.warn("Decompress gzip", .{});

                        var stream = try gzip.gzipStream(allocator, client_reader);
                        defer stream.deinit();

                        feed_resp.body = try stream.reader().readAllAlloc(allocator, len);
                    },
                    .deflate => {
                        l.warn("Decompress deflate", .{});

                        var window_slice = try allocator.alloc(u8, 32 * 1024);
                        defer allocator.free(window_slice);

                        var stream = std.compress.deflate.inflateStream(client_reader, window_slice);
                        feed_resp.body = try stream.reader().readAllAlloc(allocator, len);
                    },
                }
            },
            .chunked => {
                // @continue
                // TODO: parse response chunks myself
                // Try using gzip/deflate reader
                l.warn("Parse chunked response", .{});
                var output = ArrayList(u8).init(allocator);
                errdefer output.deinit();
                while (true) {
                    const len_str = try client_reader.readUntilDelimiterOrEof(&request_buf, '\r');
                    assert(len_str != null);
                    assert((try client_reader.readByte()) == '\n');
                    var chunk_len = try std.fmt.parseUnsigned(usize, len_str.?, 16);
                    if (chunk_len == 0) break;
                    try output.ensureCapacity(output.items.len + chunk_len);
                    l.warn("chunk_len: {}", .{chunk_len});
                    while (chunk_len > 0) {
                        const size = try client_reader.read(&request_buf);
                        const buf_len = if (size > chunk_len) chunk_len else size;
                        chunk_len -= buf_len;
                        output.appendSliceAssumeCapacity(request_buf[0..buf_len]);
                        // l.warn("|start|{s}|end|", .{request_buf[0..buf_len]});
                    }
                    // break;
                }

                feed_resp.body = output.toOwnedSlice();

                // switch (content_encoding) {
                //     .none => {
                //         l.warn("No compression", .{});
                //         feed_resp.body = output.toOwnedSlice();
                //     },
                //     .gzip => {
                //         l.warn("Decompress gzip", .{});
                //         l.warn("output.len: {}", .{output.items.len});
                //         defer output.deinit();
                //         const reader = std.io.fixedBufferStream(output.items).reader();

                //         var stream = try gzip.gzipStream(allocator, reader);
                //         defer stream.deinit();

                //         var body = try stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
                //         errdefer allocator.free(body);
                //         feed_resp.body = body;
                //     },
                //     .deflate => {
                //         l.warn("Decompress deflate", .{});
                //         l.warn("output.len: {}", .{output.items.len});
                //         defer output.deinit();
                //         const reader = std.io.fixedBufferStream(output.items).reader();

                //         var window_slice = try allocator.alloc(u8, 32 * 1024);
                //         defer allocator.free(window_slice);

                //         var stream = std.compress.deflate.inflateStream(reader, window_slice);
                //         var body = try stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
                //         errdefer allocator.free(body);
                //         feed_resp.body = body;
                //     },
                // }
            },
        }

        return feed_resp;
    }

    const Url = struct {
        domain: []const u8,
        path: []const u8,
    };

    // https://www.whogohost.com/host/knowledgebase/308/Valid-Domain-Name-Characters.html
    // https://stackoverflow.com/a/53875771
    // NOTE: urls with port will error
    // NOTE: https://localhost will error
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
};

pub fn select(comptime T: type, allocator: *Allocator, db: *sql.Db, comptime query: []const u8, opts: anytype) !?T {
    return db.oneAlloc(T, allocator, query, .{}, opts) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn selectAll(
    comptime T: type,
    allocator: *Allocator,
    db: *sql.Db,
    comptime query: []const u8,
    opts: anytype,
) ![]T {
    var stmt = try db.prepare(query);
    defer stmt.deinit();
    return stmt.all(T, allocator, .{}, opts) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn printAllItems(db: *sql.Db, allocator: *Allocator) !void {
    const Result = struct {
        title: []const u8,
        link: ?[]const u8,
    };
    // NOTE: in case of DESC pub_date_utc null values got to the end of table
    const query =
        \\SELECT title, link FROM item
        \\ORDER BY pub_date_utc DESC, created_at ASC
    ;
    var stmt = try db.prepare(query);
    defer stmt.deinit();
    const all_items = stmt.all(Result, allocator, .{}, .{}) catch |err| {
        l.warn("ERR: {s}\nFailed query:\n{}", .{ db.getDetailedError().message, query });
        return err;
    };
    const writer = std.io.getStdOut().writer();
    for (all_items) |item| {
        const link = item.link orelse "<no-link>";
        try writer.print("{s}: {s}\n", .{ item.title, link });
    }
}

// Using arena allocator so all memory will be freed by arena allocator
pub fn cliAddFeed(db: *sql.Db, allocator: *Allocator, location_raw: []const u8) !void {
    var location = try makeFilePath(allocator, location_raw);
    var contents = try getLocalFileContents(allocator, location);
    var rss_feed = try rss.Feed.init(allocator, location, contents);

    const feed_id = try addFeed(db, rss_feed);

    try insert(db, Table.feed_update.insert ++ Table.feed_update.on_conflict_feed_id, .{
        feed_id,
        rss_feed.info.ttl,
    });

    try addFeedItems(db, rss_feed.items, feed_id);
}

pub fn insert(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    @setEvalBranchQuota(2000);

    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

pub fn update(db: *sql.Db, comptime query: []const u8, args: anytype) !void {
    db.exec(query, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

// Non-alloc select query that returns one or none rows
pub fn one(comptime T: type, db: *sql.Db, comptime query: []const u8, args: anytype) !?T {
    return db.one(T, query, .{}, args) catch |err| {
        l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, query });
        return err;
    };
}

// test "add feed" {
//     var allocator = testing.allocator;
//     var location_raw: []const u8 = "./test/sample-rss-2.xml";

//     var db = try memoryDb();
//     try dbSetup(&db);

//     var db_item = Item{
//         .allocator = allocator,
//         .db = &db,
//     };

//     var db_feed_update = FeedUpdate{
//         .allocator = allocator,
//         .db = &db,
//     };

//     var location = try makeFilePath(allocator, location_raw);
//     defer allocator.free(location);

//     var contents = try getLocalFileContents(allocator, location);
//     defer allocator.free(contents);

//     var rss_feed = try rss.Feed.init(allocator, location, contents);
//     defer rss_feed.deinit();

//     var db_feed = Feed.init(allocator, &db);

//     const feed_id = try addFeed(db_feed, rss_feed);

//     try insert(&db, Table.feed_update.insert, .{
//         feed_id,
//         rss_feed.info.ttl,
//         rss_feed.info.last_build_date,
//         rss_feed.info.last_build_date_utc,
//     });
//     {
//         const updates = try db_feed_update.selectAll();
//         defer db_feed_update.allocator.free(updates);
//         testing.expect(1 == updates.len);
//         for (updates) |u| {
//             testing.expect(feed_id == u.feed_id);
//         }
//     }

//     try addFeedItems(&db, rss_feed.items, feed_id);

//     {
//         try addFeedItems(&db, rss_feed.items, feed_id);
//         // var items = try db_item.selectAll();
//         // defer {
//         //     for (items) |it| {
//         //         l.warn("{s}", .{it.title});
//         //         db_item.allocator.free(it.title);
//         //         db_item.allocator.free(it.link);
//         //         db_item.allocator.free(it.pub_date);
//         //         db_item.allocator.free(it.created_at);
//         //     }
//         //     db_item.allocator.free(items);
//         // }
//     }

//     const items_count = try one(usize, &db, Table.item.count_all, .{});
//     testing.expectEqual(rss_feed.items.len, items_count.?);
// }

pub const FeedUpdate = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    const Raw = struct {
        etag: ?[]const u8,
        feed_id: usize,
        update_interval: usize,
        last_update: i64,
        ttl: ?usize,
        last_build_date_utc: ?i64,
        expires_utc: ?i64,
        last_modified_utc: ?i64,
        cache_control_max_age: ?i64,
    };

    pub fn selectAll(feed_update: Self) ![]Raw {
        var stmt = try feed_update.db.prepare(Table.feed_update.selectAll);
        defer stmt.deinit();
        return stmt.all(Raw, feed_update.allocator, .{}, .{}) catch |err| {
            l.warn("FeedUpdate.selectAll() failed. ERR: {s}\n", .{
                feed_update.db.getDetailedError().message,
            });
            return err;
        };
    }
};

pub fn addFeedItems(db: *sql.Db, feed_items: []rss.Item, feed_id: usize) !void {
    for (feed_items) |it| {
        if (it.guid) |_| {
            try insert(
                db,
                Table.item.insert ++ Table.item.on_conflict_guid,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        } else if (it.link) |_| {
            try insert(
                db,
                Table.item.insert ++ Table.item.on_conflict_link,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        } else if (it.pub_date != null and
            try one(bool, db, Table.item.has_item, .{ feed_id, it.pub_date_utc }) != null)
        {
            // Updates row if it matches feed_id and pub_date_utc
            try update(db, Table.item.update_without_guid_and_link, .{
                // set column values
                it.title, it.link,         it.guid,
                // where
                feed_id,  it.pub_date_utc,
            });
        } else {
            try insert(
                db,
                Table.item.insert,
                .{ feed_id, it.title, it.link, it.guid, it.pub_date, it.pub_date_utc },
            );
        }
    }
}

const Item = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    const Raw = struct {
        title: []const u8,
        link: []const u8,
        pub_date: []const u8,
        created_at: []const u8,
        // TODO: add guid: ?[]const u8
        // TODO: add pub_date_utc: ?i64
        feed_id: usize,
        id: usize,
    };

    pub fn deinitRaw(link: Self, raw: ?Raw) void {
        if (raw) |r| {
            link.allocator.free(r.title);
            link.allocator.free(r.link);
            link.allocator.free(r.pub_date);
            link.allocator.free(r.created_at);
        }
    }

    pub fn selectAll(item: Self) ![]Raw {
        var all_items = ArrayList(Raw).init(item.allocator);
        errdefer all_items.deinit();
        var all = try item.db.prepare(Table.item.select_all);
        defer all.deinit();
        var iter = try all.iterator(Raw, .{});
        while (try iter.nextAlloc(item.allocator, .{})) |link_row| {
            try all_items.append(link_row);
        }
        return all_items.toOwnedSlice();
    }
};

// location has to be absolute
pub fn getLocalFileContents(allocator: *Allocator, abs_location: []const u8) ![]const u8 {
    const local_file = try std.fs.openFileAbsolute(abs_location, .{});
    defer local_file.close();
    var file_stat = try local_file.stat();

    return try local_file.reader().readAllAlloc(allocator, file_stat.size);
}

pub fn addFeed(db: *sql.Db, rss_feed: rss.Feed) !usize {
    try insert(db, Table.feed.insert ++ Table.feed.on_conflict_location, .{
        rss_feed.info.title,
        rss_feed.info.link,
        rss_feed.info.location,
        rss_feed.info.pub_date,
        rss_feed.info.pub_date_utc,
        rss_feed.info.last_build_date,
        rss_feed.info.last_build_date_utc,
    });

    // Just inserted feed, it has to exist
    const id = (try one(
        usize,
        db,
        Table.feed.select_id ++ Table.feed.where_location,
        .{rss_feed.info.location},
    )).?;
    return id;
}

pub const Feed = struct {
    const Self = @This();
    allocator: *Allocator,
    db: *sql.Db,

    pub const Raw = struct {
        title: []const u8,
        link: []const u8,
        location: []const u8,
        id: usize,
        pub_date_utc: ?i64,
    };

    pub fn deinitRaw(feed: Self, raw: ?Raw) void {
        if (raw) |r| {
            feed.allocator.free(r.title);
            feed.allocator.free(r.link);
            feed.allocator.free(r.location);
        }
    }

    pub fn init(allocator: *Allocator, db: *sql.Db) Self {
        return Self{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn select(feed: Self) !?Raw {
        const db = feed.db;
        const allocator = feed.allocator;
        return db.oneAlloc(Raw, allocator, Table.feed.select, .{}, .{}) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select,
                db.getDetailedError().message,
            });
            return err;
        };
    }

    pub fn selectLocation(feed: Self, location: []const u8) !?Raw {
        const db = feed.db;
        const allocator = feed.allocator;
        return db.oneAlloc(
            Raw,
            allocator,
            Table.feed.select ++ Table.feed.where_location,
            .{},
            .{location},
        ) catch |err| {
            l.warn("Failed query `{s}`. ERR: {s}\n", .{
                Table.feed.select ++ Table.feed.where_location,
                db.getDetailedError().message,
            });
            return err;
        };
    }
};

pub fn memoryDb() !sql.Db {
    var db: sql.Db = undefined;
    try db.init(.{
        .mode = sql.Db.Mode.Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
        // .threading_mode = .SingleThread,
    });
    return db;
}

pub fn tmpDb() !sql.Db {
    var db: sql.Db = undefined;
    try db.init(.{
        .mode = sql.Db.Mode{ .File = "/media/hdd/code/feed_inbox/tmp/test.db" },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    return db;
}

fn dbSetup(db: *sql.Db) !void {
    _ = try db.pragma(usize, .{}, "foreign_keys", .{"1"});

    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasDecl(decl.data.Type, "create")) {
            const sql_create = @field(decl.data.Type, "create");
            db.exec(sql_create, .{}) catch |err| {
                l.warn("SQL_ERROR: {s}\n Failed query:\n{s}", .{ db.getDetailedError().message, sql_create });
                return err;
            };
        }
    }

    const version: usize = 1;
    try insert(db, Table.setting.insert, .{version});
}

pub fn verifyDbTables(db: *sql.Db) bool {
    const select_table = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;";
    inline for (@typeInfo(Table).Struct.decls) |decl| {
        if (@hasField(decl.data.Type, "create")) {
            const row = one(usize, db, select_table, .{decl.name});
            if (row == null) return false;
            break;
        }
    }

    return true;
}

pub fn makeFilePath(allocator: *Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try mem.dupe(allocator, u8, path);
    }
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
}

const Setting = struct {
    version: usize,

    pub fn select(allocator: *Allocator, db: *sql.Db) !?Setting {
        return db.oneAlloc(Setting, allocator, Table.setting.select, .{}, .{}) catch |err| {
            l.warn("Failed to get setting. ERR: {s}\n", .{db.getDetailedError().message});
            return err;
        };
    }
};

// test "verifyDbTables" {
//     var allocator = testing.allocator;
//     var db = try memoryDb();

//     try dbSetup(&db);
//     const result = verifyDbTables(&db);
//     assert(result);
//     const setting = (try Setting.select(allocator, &db)).?;
//     assert(1 == setting.version);
// }
