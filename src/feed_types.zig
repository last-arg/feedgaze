const std = @import("std");
const Uri = std.Uri;
const dt = @import("zig-datetime").datetime;
const HeaderValues = @import("./http_client.zig").HeaderValues;

pub const Feed = struct {
    const Self = @This();
    feed_id: usize = 0,
    title: ?[]const u8 = null,
    feed_url: []const u8,
    page_url: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    pub const Error = error{
        InvalidUri,
    };

    pub fn prepareAndValidate(self: *Self, fallback_url: ?[]const u8) !void {
        if (self.feed_url.len == 0 and fallback_url == null) {
            return error.NoFeedUrl;
        }
        if (self.feed_url.len == 0) {
            self.feed_url = fallback_url.?;
        }
        _ = Uri.parse(self.feed_url) catch return Error.InvalidUri;
        if (self.updated_raw) |date| {
            self.updated_timestamp = AtomDateTime.parse(date) catch RssDateTime.parse(date) catch null;
        }
    }
};

// https://www.rfc-editor.org/rfc/rfc4287#section-3.3
const AtomDateTime = struct {
    pub fn parse(raw: []const u8) !i64 {
        const year = std.fmt.parseUnsigned(u16, raw[0..4], 10) catch return error.InvalidFormat;
        const month = std.fmt.parseUnsigned(u16, raw[5..7], 10) catch return error.InvalidFormat;
        const day = std.fmt.parseUnsigned(u16, raw[8..10], 10) catch return error.InvalidFormat;
        const hour = std.fmt.parseUnsigned(u16, raw[11..13], 10) catch return error.InvalidFormat;
        const minute = std.fmt.parseUnsigned(u16, raw[14..16], 10) catch return error.InvalidFormat;
        const second = std.fmt.parseUnsigned(u16, raw[17..19], 10) catch return error.InvalidFormat;
        const tz = blk: {
            if (raw[raw.len - 1] == 'Z') {
                break :blk dt.Timezone.create("Z", 0);
            } else {
                const sign_index = raw.len - 6;
                const sign_raw = raw[sign_index];
                if (sign_raw != '+' and sign_raw != '-') {
                    return error.InvalidError;
                }

                const tz_hour = std.fmt.parseInt(i16, raw[sign_index + 1 .. sign_index + 3], 10) catch return error.InvalidFormat;
                const tz_min = std.fmt.parseUnsigned(i16, raw[sign_index + 4 .. sign_index + 6], 10) catch return error.InvalidFormat;
                // This is based on '+' and '-' ascii numeric values
                const sign = -1 * (@as(i16, sign_raw) - 44);
                break :blk dt.Timezone.create(raw[sign_index..], sign * ((tz_hour * 60) + tz_min));
            }
            return error.InvalidFormat;
        };

        const datetime = dt.Datetime.create(year, month, day, hour, minute, second, 0, &tz) catch return error.InvalidFormat;
        return @intCast(i64, @divTrunc(datetime.toTimestamp(), 1000));
    }
};

test "AtomDateTime.parse" {
    const d1 = try AtomDateTime.parse("2003-12-13T18:30:02Z");
    try std.testing.expectEqual(@as(i64, 1071340202), d1);
    const d2 = try AtomDateTime.parse("2003-12-13T18:30:02.25Z");
    try std.testing.expectEqual(@as(i64, 1071340202), d2);
    const d3 = try AtomDateTime.parse("2003-12-13T18:30:02.25+01:00");
    try std.testing.expectEqual(@as(i64, 1071336602), d3);
}

// https://www.w3.org/Protocols/rfc822/#z28
pub const RssDateTime = struct {
    pub const Timezone = enum {
        UT,
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
                const result: i8 = switch (tz) {
                    .UT, .GMT => 0,
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
                return @intCast(u8, i) + 1;
            }
        }
        return error.InvalidMonth;
    }

    pub fn parse(str: []const u8) !i64 {
        var ctx = str;
        if (ctx[3] == ',') {
            // NOTE: Start day and comma (,) are optional
            ctx = ctx[5..];
        }
        const day = std.fmt.parseUnsigned(u8, ctx[0..2], 10) catch return error.InvalidFormat;
        const month = parseMonth(ctx[3..6]) catch return error.InvalidFormat;
        ctx = ctx[7..];
        var end_index = std.mem.indexOfScalar(u8, ctx, ' ') orelse return error.InvalidFormat;
        var year = std.fmt.parseUnsigned(u16, ctx[0..end_index], 10) catch return error.InvalidFormat;
        if (year < 100) {
            // NOTE: Assuming two letter length year is a year after 2000
            year += 2000;
        }
        ctx = ctx[end_index + 1 ..];
        const hour = std.fmt.parseUnsigned(u8, ctx[0..2], 10) catch return error.InvalidFormat;
        const minute = std.fmt.parseUnsigned(u8, ctx[3..5], 10) catch return error.InvalidFormat;
        const second = blk: {
            if (ctx[5] == ':') {
                break :blk std.fmt.parseUnsigned(u8, ctx[6..8], 10) catch return error.InvalidFormat;
            }
            break :blk 0;
        };
        end_index = std.mem.lastIndexOfScalar(u8, ctx, ' ') orelse return error.InvalidFormat;
        const tz_name = ctx[end_index + 1 ..];
        const tz_min = Timezone.toMinutes(tz_name) catch return error.InvalidFormat;
        const tz = dt.Timezone.create(tz_name, tz_min);

        const datetime = dt.Datetime.create(year, month, day, hour, minute, second, 0, &tz) catch return error.InvalidFormat;
        return @intCast(i64, @divTrunc(datetime.toTimestamp(), 1000));
    }
};

test "RssDateTime.parse" {
    const d1 = try RssDateTime.parse("Sat, 07 Sep 2002 07:37:01 A");
    try std.testing.expectEqual(@as(i64, 1031387821), d1);
    const d2 = try RssDateTime.parse("07 Sep 02 07:37:01 -0100");
    try std.testing.expectEqual(@as(i64, 1031387821), d2);
    const d3 = try RssDateTime.parse("07 Sep 02 18:02 -0130");
    try std.testing.expectEqual(@as(i64, 1031427120), d3);
}

pub const FeedItem = struct {
    feed_id: usize = 0,
    item_id: ?usize = null,
    title: []const u8,
    id: ?[]const u8 = null,
    link: ?[]const u8 = null,
    updated_raw: ?[]const u8 = null,
    updated_timestamp: ?i64 = null,

    const Self = @This();

    pub fn prepareAndValidate(self: *Self, feed_id: usize) !void {
        self.feed_id = feed_id;
        if (self.updated_raw) |date| {
            self.updated_timestamp = AtomDateTime.parse(date) catch RssDateTime.parse(date) catch null;
        }
    }

    pub fn prepareAndValidateAll(items: []Self, feed_id: usize) !void {
        for (items) |*item| {
            try item.prepareAndValidate(feed_id);
        }
    }
};

pub const FeedUpdate = struct {
    feed_id: ?usize = null,
    cache_control_max_age: ?u32 = null,
    expires_utc: ?i64 = null,
    last_modified_utc: ?i64 = null,
    etag: ?[]const u8 = null,

    pub fn fromHeaders(headers: HeaderValues, feed_id: ?usize) @This() {
        return .{
            .feed_id = feed_id,
            .cache_control_max_age = headers.max_age,
            .expires_utc = headers.expires,
            .last_modified_utc = headers.last_modified,
            .etag = headers.etag,
        };
    }
};

pub const ContentType = enum {
    rss,
    atom,
    xml,

    pub fn fromString(input: []const u8) ?@This() {
        if (std.ascii.eqlIgnoreCase(input, "application/rss+xml")) {
            return .rss;
        } else if (std.ascii.eqlIgnoreCase(input, "application/atom+xml")) {
            return .atom;
        } else if (std.ascii.eqlIgnoreCase(input, "application/xml") or std.ascii.eqlIgnoreCase(input, "text/xml")) {
            return .xml;
        }
        return null;
    }
};

pub const FeedToUpdate = struct {
    feed_id: usize,
    feed_url: []const u8,
    expires_utc: ?i64 = null,
    last_modified_utc: ?i64 = null,
    etag: ?[]const u8 = null,
};
