const std = @import("std");
const Uri = std.Uri;
const dt = @import("zig-datetime").datetime;
const curl = @import("curl");

pub const FetchHeaderOptions = struct {
    etag: ?[]const u8 = null,
    last_modified_utc: ?i64 = null,
};

pub const ShowOptions = struct {
    limit: usize = 10,
    @"item-limit": usize = 10,

    pub const shorthands = .{
        .l = "limit",
    };
};

pub const TagOptions = struct {
    list: bool = false,
    remove: bool = false,
    feed: ?[]const u8 = null,
    // @"remove-unused": bool = false,
};

pub const AddOptions = struct {
    tags: ?[]const u8 = null
};

pub const UpdateOptions = struct {
    // Will ignore 'feed_update.update_countdown'
    force: bool = false,
};

pub const Feed = struct {
    const Self = @This();
    feed_id: usize = 0,
    title: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    pub const Error = error{
        InvalidUri,
    };

    pub fn prepareAndValidate(self: *Self, alloc: std.mem.Allocator) !void {
        const feed_uri = Uri.parse(self.feed_url) catch |err| {
            std.log.err("'feed_url' should always be valid url. Got '{s}'", .{self.feed_url});
            return err;
        };
        if (self.page_url) |page_url| {
            if (page_url[0] == '/' or page_url[0] == '.') {
                var buf = try alloc.alloc(u8, self.feed_url.len + page_url.len);
                const result = try feed_uri.resolve_inplace(page_url, &buf);
                self.page_url = try std.fmt.allocPrint(alloc, "{}", .{result});
            }
        }
    }
};

// https://www.rfc-editor.org/rfc/rfc4287#section-3.3
pub const AtomDateTime = struct {
    pub fn parse(input: []const u8) !i64 {
        const raw = std.mem.trimLeft(u8, input, &std.ascii.whitespace);
        const year = std.fmt.parseUnsigned(u16, raw[0..4], 10) catch return error.InvalidFormat;
        const month = std.fmt.parseUnsigned(u16, raw[5..7], 10) catch return error.InvalidFormat;
        const day = std.fmt.parseUnsigned(u16, raw[8..10], 10) catch return error.InvalidFormat;
        const hour = std.fmt.parseUnsigned(u16, raw[11..13], 10) catch return error.InvalidFormat;
        const minute = std.fmt.parseUnsigned(u16, raw[14..16], 10) catch return error.InvalidFormat;
        const second = std.fmt.parseUnsigned(u16, raw[17..19], 10) catch return error.InvalidFormat;
        const tz = blk: {
            const sign_index = raw.len - 6;
            if (raw[raw.len - 1] == 'Z') {
                break :blk dt.Timezone.create("Z", 0);
            } else if (raw[sign_index] == '+' or raw[sign_index] == '-') {
                const sign_raw = raw[sign_index];

                const tz_hour = std.fmt.parseInt(i16, raw[sign_index + 1 .. sign_index + 3], 10) catch return error.InvalidFormat;
                const tz_min = std.fmt.parseUnsigned(i16, raw[sign_index + 4 .. sign_index + 6], 10) catch return error.InvalidFormat;
                // This is based on '+' and '-' ascii numeric values
                const sign = -1 * (@as(i16, sign_raw) - 44);
                break :blk dt.Timezone.create(raw[sign_index..], sign * ((tz_hour * 60) + tz_min));
            } else {
                // Out of spec, default to "Z" time zone
                break :blk dt.Timezone.create("Z", 0);
            }
            return error.InvalidFormat;
        };

        const datetime = dt.Datetime.create(year, month, day, hour, minute, second, 0, &tz) catch return error.InvalidFormat;
        return @as(i64, @intCast(@divTrunc(datetime.toTimestamp(), 1000)));
    }
};

test "AtomDateTime.parse" {
    const d1 = try AtomDateTime.parse("2003-12-13T18:30:02Z");
    try std.testing.expectEqual(@as(i64, 1071340202), d1);
    const d2 = try AtomDateTime.parse("2003-12-13T18:30:02.25Z");
    try std.testing.expectEqual(@as(i64, 1071340202), d2);
    const d3 = try AtomDateTime.parse("2003-12-13T18:30:02.25+01:00");
    try std.testing.expectEqual(@as(i64, 1071336602), d3);
    const d4 = try AtomDateTime.parse("2024-02-14T13:21:31");
    // from: https://andy-bell.co.uk/feed.xml
    try std.testing.expectEqual(@as(i64, 1707916891), d4);
}

// https://www.w3.org/Protocols/rfc822/#z28
pub const RssDateTime = struct {
    pub const Timezone = enum {
        UT,
        UTC,
        GMT,
        EST,
        EDT,
        CST,
        CDT,
        MST,
        MDT,
        PST,
        PDT,
        A,
        M,
        N,
        Y,

        pub fn toMinutes(raw: []const u8) !i16 {
            // Timezone is made of letters
            if (std.meta.stringToEnum(@This(), raw)) |tz| {
                const result: i16 = switch (tz) {
                    .UT, .GMT, .UTC => 0,
                    .EST => -5,
                    .EDT => -4,
                    .CST => -6,
                    .CDT => -5,
                    .MST => -7,
                    .MDT => -6,
                    .PST => -8,
                    .PDT => -7,
                    .A => -1,
                    .M => -12,
                    .N => 1,
                    .Y => 12,
                };
                return result * 60;
            }

            // Timezone is made of numbers
            const first = raw[0];
            if (raw.len == 5 and first != '+' and first != '-') {
                return error.InvalidFormat;
            }
            const hour = std.fmt.parseInt(i16, raw[1..3], 10) catch return error.InvalidFormat;
            const min = std.fmt.parseUnsigned(i16, raw[3..5], 10) catch return error.InvalidFormat;
            // This is based on '+' and '-' ascii numeric values
            const sign = -1 * (@as(i16, first) - 44);
            return sign * ((hour * 60) + min);
        }
    };

    fn parseMonth(raw: []const u8) !u8 {
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        for (months, 0..) |month, i| {
            if (std.mem.eql(u8, raw, month)) {
                return @as(u8, @intCast(i)) + 1;
            }
        }
        return error.InvalidMonth;
    }

    pub fn parse(input: []const u8) !i64 {
        const str = std.mem.trimLeft(u8, input, &std.ascii.whitespace);
        var ctx = str;
        if (ctx[3] == ',') {
            // NOTE: Start day and comma (,) are optional
            ctx = ctx[5..];
        }
        var end_index = std.mem.indexOfScalar(u8, ctx, ' ') orelse return error.InvalidFormat;
        const day = std.fmt.parseUnsigned(u8, ctx[0..end_index], 10) catch return error.InvalidFormat;
        ctx = ctx[end_index + 1 ..];
        const month = parseMonth(ctx[0..3]) catch return error.InvalidFormat;
        end_index = std.mem.indexOfScalar(u8, ctx, ' ') orelse return error.InvalidFormat;
        ctx = ctx[end_index + 1 ..];
        end_index = std.mem.indexOfScalar(u8, ctx, ' ') orelse return error.InvalidFormat;
        var year = std.fmt.parseUnsigned(u16, ctx[0..end_index], 10) catch return error.InvalidFormat;
        if (year < 100) {
            // NOTE: Assuming two letter length year is a year after 2000
            year += 2000;
        }
        ctx = ctx[end_index + 1 ..];
        end_index = std.mem.indexOfScalar(u8, ctx, ':') orelse return error.InvalidFormat;
        const hour = std.fmt.parseUnsigned(u8, ctx[0..end_index], 10) catch return error.InvalidFormat;
        ctx = ctx[end_index + 1 ..];
        const minute = std.fmt.parseUnsigned(u8, ctx[0..2], 10) catch return error.InvalidFormat;
        const second = blk: {
            if (ctx[2] == ':') {
                break :blk std.fmt.parseUnsigned(u8, ctx[3..5], 10) catch return error.InvalidFormat;
            }
            break :blk 0;
        };
        end_index = std.mem.lastIndexOfScalar(u8, ctx, ' ') orelse return error.InvalidFormat;
        const tz_name = ctx[end_index + 1 ..];
        const tz_min = Timezone.toMinutes(tz_name) catch return error.InvalidFormat;
        const tz = dt.Timezone.create(tz_name, tz_min);

        const datetime = dt.Datetime.create(year, month, day, hour, minute, second, 0, &tz) catch return error.InvalidFormat;
        return @as(i64, @intCast(@divTrunc(datetime.toTimestamp(), 1000)));
    }
};

test "RssDateTime.parse" {
    const d1 = try RssDateTime.parse("Sat, 07 Sep 2002 07:37:01 A");
    try std.testing.expectEqual(@as(i64, 1031387821), d1);
    const d2 = try RssDateTime.parse("07 Sep 02 07:37:01 -0100");
    try std.testing.expectEqual(@as(i64, 1031387821), d2);
    const d3 = try RssDateTime.parse("07 Sep 02 18:02 -0130");
    try std.testing.expectEqual(@as(i64, 1031427120), d3);
    // from: https://blog.ploeh.dk/rss.xml
    const d4 = try RssDateTime.parse("Mon, 12 Feb 2024 07:00:00 UTC");
    try std.testing.expectEqual(@as(i64, 1707721200), d4);
    // from:
    // - https://verdagon.dev/rss.xml
    // - https://feeds.simplecast.com/L9810DOa
    // date has single number
    const d5 = try RssDateTime.parse("Tue, 5 Jan 2021 12:00:00 -0400");
    try std.testing.expectEqual(@as(i64, 1609862400), d5);
    // from: https://verdagon.dev/rss.xml
    // hours has single number
    const d6 = try RssDateTime.parse("Tue, 15 Jun 2023 0:00:00 -0500");
    try std.testing.expectEqual(@as(i64, 1686805200), d6);
    // from: https://verdagon.dev/rss.xml
    // month value is too long
    const d7 = try RssDateTime.parse("Thu, 28 June 2022 10:15:00 -0400");
    try std.testing.expectEqual(@as(i64, 1656425700), d7);
    // revealed an integer overflow bug
    const d8 = try RssDateTime.parse("Mon, 4 Dec 2023 09:00:00 PST");
    try std.testing.expectEqual(@as(i64, 1701709200), d8);
}

pub const FeedItem = struct {
    feed_id: usize = 0,
    // TODO: this should not be null. See if there is a reason why I marked it
    // as null? Probably item_id is null before adding item to DB. Have
    // different types for inserting and retrieving item?
    item_id: ?usize = null,
    title: []const u8,
    id: ?[]const u8 = null,
    link: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    const Self = @This();
};

pub const FeedItemRender = struct {
    title: []const u8,
    link: ?[]const u8,
    updated_timestamp: ?i64,
};

pub const FeedRender = struct {
    feed_id: usize,
    title: []const u8,
    feed_url: []const u8,
    page_url: ?[]const u8,
    updated_timestamp: ?i64,
};

pub const FeedUpdate = struct {
    last_modified_utc: ?i64 = null,
    etag: ?[]const u8 = null,
    update_interval: i64 = @import("./app_config.zig").update_interval,

    pub fn fromCurlHeaders(easy: curl.Easy.Response) @This() {
        var feed_update = FeedUpdate{};

        if (easy.getHeader("last-modified")) |header| {
            if (header) |h| {
                feed_update.last_modified_utc = RssDateTime.parse(h.get()) catch null;
            }
        } else |_| {}

        if (easy.getHeader("etag")) |header| {
            if (header) |h| {
                feed_update.etag = h.get();
            }
        } else |_| {}

        var update_interval: ?i64 = null;
        if (easy.getHeader("cache-control")) |header| {
            if (header) |h| {
                const value = h.get();
                var iter = std.mem.split(u8, value, ",");
                while (iter.next()) |key_value| {
                    var pair_iter = std.mem.split(u8, key_value, "=");
                    var key = pair_iter.next() orelse continue;
                    key = std.mem.trim(u8, key, &std.ascii.whitespace);
                    var iter_value = pair_iter.next() orelse continue;
                    iter_value = std.mem.trim(u8, iter_value, &std.ascii.whitespace);
                    // TODO: look more into how 'cache-control' works
                    if (std.mem.eql(u8, "max-age", key)) {
                        update_interval = std.fmt.parseUnsigned(u32, iter_value, 10) catch continue;
                    } else if (std.mem.eql(u8, "s-maxage", value)) {
                        update_interval = std.fmt.parseUnsigned(u32, iter_value, 10) catch continue;
                        break;
                    }
                }
            }
        } else |_| {}

        if (update_interval == 0) {
            update_interval = null;
        }

        if (easy.getHeader("expires")) |header| {
            if (header) |h| {
                const value = RssDateTime.parse(h.get()) catch null;
                if (value) |v| {
                    const interval = v - std.time.timestamp();
                    // Favour cache-control value over expires
                    if (interval > 0 and update_interval == null) {
                        update_interval = interval;
                    }
                }
            }
        } else |_| {}

        if (update_interval) |value| {
            feed_update.update_interval = value;
        }

        return feed_update;
    }

    pub fn fromHeaders(headers: std.http.Headers) @This() {
        const last_modified = blk: {
            if (headers.getFirstValue("last-modified")) |value| {
                break :blk RssDateTime.parse(value) catch null;
            }

            break :blk null;
        };

        const expires = blk: {
            if (headers.getFirstValue("expires")) |value| {
                break :blk RssDateTime.parse(value) catch null;
            }

            break :blk null;
        };

        const cache_control = blk: {
            var result: ?u32 = null;
            if (headers.getFirstValue("cache-control")) |value| {
                var iter = std.mem.split(u8, value, ",");
                while (iter.next()) |key_value| {
                    var pair_iter = std.mem.split(u8, key_value, "=");
                    const key = pair_iter.next() orelse continue;
                    const iter_value = pair_iter.next() orelse continue;
                    if (std.mem.eql(u8, "max-age", key)) {
                        result = std.fmt.parseUnsigned(u32, iter_value, 10) catch continue;
                        break;
                    } else if (std.mem.eql(u8, "s-maxage", value)) {
                        result = std.fmt.parseUnsigned(u32, iter_value, 10) catch continue;
                    }
                }
            }

            break :blk result;
        };

        return .{
            .cache_control_max_age = cache_control,
            .expires_utc = expires,
            .last_modified_utc = last_modified,
            .etag = headers.getFirstValue("etag"),
        };
    }
};

pub const ContentType = enum {
    rss,
    atom,
    xml,
    html,

    pub fn fromString(input: []const u8) ?@This() {
        if (mightBeEncodedContentType(input)) |ct| {
            return ct;
        }
        if (std.ascii.startsWithIgnoreCase(input, "application/xml") or std.ascii.startsWithIgnoreCase(input, "text/xml")) {
            return .xml;
        } else if (std.ascii.startsWithIgnoreCase(input, "text/html")) {
            return .html;
        }
        return null;
    }

    fn mightBeEncodedContentType(str: []const u8) ?ContentType {
        const encoded_plus = "&#43;";
        const start_rss = "application/rss";
        const start_atom = "application/atom";
        var result: ContentType = undefined;
        const rest = blk: {
            if (std.ascii.startsWithIgnoreCase(str, start_rss)) {
                result = .xml;
                break :blk str[start_rss.len..];
            } else if (std.ascii.startsWithIgnoreCase(str, start_atom)) {
                result = .atom;
                break :blk str[start_atom.len..];
            }
            break :blk "";
        };
        if (rest.len == 0) {
            return null;
        }
        var rest_start: usize = 0;

        if (rest[0] == '+') {
            rest_start = 1;
        } else if (rest.len >= 5 and std.mem.startsWith(u8, rest, encoded_plus)) {
            rest_start = encoded_plus.len;
        }
        if (rest_start != 0 and std.ascii.startsWithIgnoreCase("xml", rest[rest_start..])) {
            return result;
        }

        return null;
    }
};

pub const FeedToUpdate = struct {
    feed_id: usize,
    feed_url: []const u8,
    last_modified_utc: ?i64 = null,
    etag: ?[]const u8 = null,
};

pub const FeedOptions = struct {
    body: []const u8 = "",
    content_type: ?ContentType = null,
    feed_updates: FeedUpdate = .{},
    feed_url: []const u8 = "",
    title: ?[]const u8 = null,

    pub fn fromResponse(resp: curl.Easy.Response) @This() {
        const header_value = resp.getHeader("content-type") catch null;
        const content_type = ContentType.fromString(if (header_value) |v| v.get() else "");
        return .{
            .body = resp.body.?.items,
            .content_type = content_type,
            .feed_updates = FeedUpdate.fromCurlHeaders(resp),
        };
    }
};
