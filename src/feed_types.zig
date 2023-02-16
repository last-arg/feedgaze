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

const RssTimezone = enum {
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
        const hour = std.fmt.parseInt(i16, raw[1..3], 10) catch return error.InvalidUri;
        const min = std.fmt.parseUnsigned(i16, raw[3..5], 10) catch return error.InvalidUri;
        // This is based on '+' and '-' ascii numeric values
        const sign = -1 * (@as(i16, first) - 44);
        return sign * ((hour * 60) + min);
    }
};

fn parseRssDateTime(str: []const u8) !void {
    _ = str;
}

test "parseRssDateTime" {
    std.debug.print("{d} {d}\n", .{ '+', '-' });
    // RssTimezone
    {
        const v1 = try RssTimezone.toMinutes("GMT");
        const v2 = try RssTimezone.toMinutes("+0300");
        const v3 = try RssTimezone.toMinutes("-0730");
        std.debug.print("{d} {d} {d}\n", .{ v1, v2, v3 });
    }
    _ = try parseRssDateTime("Sat, 07 Sep 2002 00:00:01 GMT");
    _ = try parseRssDateTime("Sat, 07 Sep 02 00:00:01 GMT");
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
