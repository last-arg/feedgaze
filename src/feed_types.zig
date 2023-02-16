const std = @import("std");
const Uri = std.Uri;

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
            // Can have two different date types
            // Rss - Sat, 07 Sep 2002 00:00:01 GMT
            //   len: 27 or 29
            //   Year can be expressed with 2 or 4 characters
            //   https://www.w3.org/Protocols/rfc822/#z28
            // Atom - 2003-12-13T18:30:02Z
            //   len: min - 20, max 28
            //   https://www.rfc-editor.org/rfc/rfc4287#section-3.3
            // TODO: validate date string
            if (date.len > 0) {
                self.updated_timestamp = @as(i64, 22);
            }
        }
    }
};

const RssDateTime = struct {
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
        for (months) |month, i| {
            if (std.mem.eql(u8, raw, month)) {
                return @intCast(u8, i) + 1;
            }
        }
        return error.InvalidMonth;
    }

    fn parse(str: []const u8) !void {
        var ctx = str;
        if (ctx[3] == ',') {
            // NOTE: Start day and comman (,) are optional
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
        const tz = Timezone.toMinutes(ctx[end_index + 1 ..]) catch return error.InvalidUri;

        std.debug.print("day: {d}\n", .{day});
        std.debug.print("month: {d}\n", .{month});
        std.debug.print("year: {d}\n", .{year});
        std.debug.print("hour: {d}\n", .{hour});
        std.debug.print("minute: {d}\n", .{minute});
        std.debug.print("second: {d}\n", .{second});
        std.debug.print("tz: {d}\n", .{tz});

        // TODO: what to return?
    }
};

test "parseRssDateTime" {
    std.debug.print("{d} {d}\n", .{ '+', '-' });
    // Timezone
    {
        const v1 = try RssDateTime.Timezone.toMinutes("GMT");
        const v2 = try RssDateTime.Timezone.toMinutes("+0300");
        const v3 = try RssDateTime.Timezone.toMinutes("-0730");
        std.debug.print("{d} {d} {d}\n", .{ v1, v2, v3 });
    }
    _ = try RssDateTime.parse("Sat, 07 Sep 2002 08:37:01 GMT");
    _ = try RssDateTime.parse("07 Sep 02 18:02 -0130");
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
        // TODO: parse date
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
};

pub const FeedToUpdate = struct {
    feed_id: usize,
    feed_url: []const u8,
    expires_utc: ?i64 = null,
    last_modified_utc: ?i64 = null,
    etag: ?[]const u8 = null,
};
