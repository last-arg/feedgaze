const std = @import("std");
const Uri = std.Uri;
const dt = @import("zdt");
const Response = @import("http_client.zig").Response;
const mem = std.mem;
const util = @import("util.zig");

pub const seconds_in_3_hours = std.time.s_per_hour * 3;
pub const seconds_in_6_hours = std.time.s_per_hour * 6;
pub const seconds_in_12_hours = std.time.s_per_hour * 12;
pub const seconds_in_1_day = std.time.s_per_day;
pub const seconds_in_2_days = seconds_in_1_day * 2;
pub const seconds_in_3_days = seconds_in_1_day * 3;
pub const seconds_in_5_days = seconds_in_1_day * 5;
pub const seconds_in_7_days = seconds_in_1_day * 7;
pub const seconds_in_10_days = seconds_in_1_day * 10;
pub const seconds_in_30_days = seconds_in_1_day * 30;

pub const FetchHeaderOptions = struct {
    etag_or_last_modified: ?[]const u8 = null,
    buffer_header: []u8,
};

pub const ShowOptions = struct {
    limit: i32 = 10,
    @"item-limit": i32 = 10,

    pub const shorthands = .{
        .l = "limit",
    };
};

pub const TagOptions = struct {
    list: bool = false,
    add: bool = false,
    remove: bool = false,
    feed: ?[]const u8 = null,
    // @"remove-unused": bool = false,
};

pub const RuleOptions = struct {
    list: bool = false,
    add: bool = false,
    remove: bool = false,
};

pub const AddOptions = struct {
    tags: ?[]const u8 = null
};

pub const BatchOptions = struct {
    @"check-all-icons": bool = false,
    @"check-missing-icons": bool = false,
    @"check-failed-icons": bool = false,
};

pub const UpdateOptions = struct {
    // Will ignore 'feed_update.update_countdown'
    force: bool = false,
};

pub const ServeOptions = struct {
    port: u16 = 1222,

    pub const shorthands = .{
        .p = "port",
    };
};

pub const Location = struct {
    offset: u32,
    len: u32,
};

// NOTE: std.Uri wrapper so can provide toValue() and fromValue() to library fridge
pub const UriWrapper = struct {
    value: std.Uri,

    pub fn init(uri: std.Uri) @This() {
        return .{ .value = uri };
    }

    pub fn from_string(str: []const u8) !@This() {
        return .{ .value = try std.Uri.parse(str) };
    }

    pub fn format(uri: *const UriWrapper, writer: *std.Io.Writer) !void {
        try std.Uri.format(&uri.value, writer);
    }

    pub fn toValue(uri: UriWrapper, arena: std.mem.Allocator) !@import("fridge").Value {
        const uri_str = try std.fmt.allocPrint(arena, "{f}", .{uri});
        return .{ .string = uri_str };
    }

    pub fn fromValue(val: @import("fridge").Value, arena: std.mem.Allocator) !UriWrapper {
        const buf: []u8 = try arena.alloc(u8, val.string.len);
        std.mem.copyForwards(u8, buf, val.string);
        return try from_string(buf);
    }
};

pub const Feed = struct {
    feed_id: ID = .unassigned,
    title: ?[]const u8 = null,
    feed_url: UriWrapper,
    page_url: ?UriWrapper = null,
    icon_id: IconRender.ID = .unassigned,
    updated_timestamp: ?i64 = null,

    pub const ID = SqliteId;

    pub const Raw = struct {
        feed_id: usize = 0,
        title: ?[]const u8 = null,
        feed_url: []const u8,
        page_url: ?[]const u8 = null,
        icon_id: ?u64 = null,
        updated_timestamp: ?i64 = null,
    };

    pub const Parsed = struct {
        title: ?Location = null,
        page_url: ?Location = null,
        updated_timestamp: ?i64 = null,
        icon_id: ?u64 = null,
    };

    pub fn from_raw(raw: Raw) !Feed {
        return .{
            .feed_id = @enumFromInt(raw.feed_id),
            .title = raw.title,
            .feed_url = try std.Uri.parse(raw.feed_url),
            .page_url = if (raw.page_url) |link| try std.Uri.parse(link) else null,
            .icon_id = if (raw.icon_id) |id| @enumFromInt(id) else .unassigned,
            .updated_timestamp = raw.updated_timestamp,
        };
    }
};

pub fn resolve_and_write_url(writer: *std.Io.Writer, input: []const u8, base_url: Uri) !void {
    if (mem.startsWith(u8, input, "http")) {
        try writer.writeAll(input);
        return;
    } else if (mem.startsWith(u8, input, "//")) {
        try writer.writeAll("https:");
        try writer.writeAll(input);
        return;
    }

    try std.Uri.writeToStream(&base_url, writer, .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .port = true,
    });

    if (input.len > 0 and input[0] != '/') {
        try writer.writeByte('/');
    }

    try writer.writeAll(input);
}

// https://www.rfc-editor.org/rfc/rfc4287#section-3.3
pub const AtomDateTime = struct {
    pub fn parse(input: []const u8) !i64 {
        const raw = std.mem.trimStart(u8, input, &std.ascii.whitespace);
        const date = dt.Datetime.fromString(raw, dt.Formats.RFC3339) catch
            dt.Datetime.fromString(input, dt.Formats.RFC3339nano) catch {
            std.log.warn("Failed to parse atom date and time. Parsed value: '{s}'", .{raw});
            return error.FailedToParseAtomDate;
        };

        return @intCast(date.toUnix(.second));
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
        Z,
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

        pub fn toSeconds(raw: []const u8) ?i16 {
            // Timezone is made of letters
            var buf: [3]u8 = undefined;
            const upper_raw = std.ascii.upperString(&buf, raw[0..@min(3, raw.len)]);
            if (raw[0] == '+' or raw[0] == '-') {
                const offset_raw = raw[1..5];
                const hour_raw = offset_raw[0..2];
                const hour = std.fmt.parseInt(i16, hour_raw, 10) catch return null;
                const minute_raw = offset_raw[2..];
                const minute = std.fmt.parseInt(i16, minute_raw, 10) catch return null;
                const sign: i8 = if (raw[0] == '+') 1 else -1;

                return sign * (hour * 60 + minute) * 60;
            } else if (std.meta.stringToEnum(@This(), upper_raw)) |tz| {
                const result: i16 = switch (tz) {
                    .UT, .GMT, .UTC, .Z => 0,
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
                return result * 60 * 60;
            }

            return null;
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
        const str = std.mem.trimStart(u8, input, &std.ascii.whitespace);
        var ctx = str;
        if (ctx.len > 3 and ctx[3] == ',') {
            // NOTE: Start day and comma (,) are optional
            ctx = ctx[5..];
        }

        const ctx_err = ctx;
        errdefer std.log.warn("Failed to parse RSS date and time. Parsed value: '{s}'", .{ctx_err});

        var date_fields: dt.Datetime.Fields = .{};

        var iter = mem.splitScalar(u8, ctx, ' ');
        const day_raw = iter.next() orelse return error.FailedToParseRssDate;
        date_fields.day = try std.fmt.parseInt(u8, day_raw, 10);

        const month_raw = iter.next() orelse return error.FailedToParseRssDate;
        date_fields.month = parseMonth(month_raw[0..@min(3, month_raw.len)]) catch return error.FailedToParseRssDate;

        const year_raw = iter.next() orelse return error.FailedToParseRssDate;
        const year = try std.fmt.parseInt(i16, year_raw, 10);
        date_fields.year = year + 2000 * @as(i16, @intFromBool(year < 100));

        blk: {
            const time_raw = iter.next() orelse break :blk;
            var time_iter = mem.splitScalar(u8, time_raw, ':');

            const hour_raw = time_iter.next() orelse break :blk;
            date_fields.hour = std.fmt.parseInt(u8, hour_raw, 10) catch break :blk;

            const minute_raw = time_iter.next() orelse break :blk;
            date_fields.minute = std.fmt.parseInt(u8, minute_raw, 10) catch break :blk;

            const second_raw = time_iter.next() orelse break :blk;
            date_fields.second = std.fmt.parseInt(u8, second_raw, 10) catch break :blk;
        }

        const tz_raw = iter.next() orelse "Z";
        if (Timezone.toSeconds(tz_raw) ) |val| blk: {
            const offset = dt.UTCoffset.fromSeconds(val, tz_raw, false) catch break :blk;
            date_fields.tz_options = .{ .utc_offset = offset };
        }

        const date = dt.Datetime.fromFields(date_fields) catch return error.FailedToParseRssDate;
        return @intCast(date.toUnix(.second));
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

const SqliteId = enum(u64) {
    unassigned = 0,
    _,

    pub fn is_valid(id: @This()) bool {
        return id != .unassigned;
    }

    pub fn toValue(val: @This(), _: std.mem.Allocator) !@import("fridge").Value {
        if (!val.is_valid()) {
            return .null;
        }
        return .{ .int = @intCast(@intFromEnum(val)) };
    }

    pub fn fromValue(val: @import("fridge").Value, _: std.mem.Allocator) !@This() {
        if (val == .null) {
            return .unassigned;
        }
        return @enumFromInt(val.int);
    }
};

pub const FeedItem = struct {
    feed_id: Feed.ID = .unassigned,
    item_id: ID = .unassigned,
    title: []const u8,
    id: ?[]const u8 = null,
    link: ?UriWrapper = null,
    updated_timestamp: ?i64 = null,

    pub const ID = SqliteId;

    pub const Parsed = struct {
        title: ?Location = null,
        id: ?Location = null,
        link: ?Location = null,
        updated_timestamp: ?i64 = null,
    };

    pub const Raw = struct {
        feed_id: u64 = 0,
        item_id: ?u64 = null,
        title: []const u8,
        id: ?[]const u8 = null,
        link: ?[]const u8 = null,
        updated_timestamp: ?i64 = null,
    };

    pub fn from_raw(raw: Raw) !FeedItem {
        return .{
            .feed_id = @enumFromInt(raw.feed_id),
            .item_id = if (raw.item_id) |id| @enumFromInt(id) else .unassigned,
            .title = raw.title,
            .id = raw.id,
            .link = if (raw.link) |link| try std.Uri.parse(link) else null, 
            .updated_timestamp = raw.updated_timestamp,
        };
    }
};

pub const FeedItemRender = struct {
    feed_id: Feed.ID,
    title: []const u8,
    link: ?UriWrapper,
    updated_timestamp: ?i64,
    created_timestamp: i64,

    pub const Raw = struct {
        feed_id: usize,
        title: []const u8,
        link: ?[]const u8,
        updated_timestamp: ?i64,
        created_timestamp: i64,
    };

    pub fn from_raw(raw: Raw) !FeedItemRender {
        return .{
            .feed_id = @enumFromInt(raw.feed_id),
            .title = raw.title,
            .link = if (raw.link) |link| try std.Uri.parse(link) else null, 
            .updated_timestamp = raw.updated_timestamp,
            .created_timestamp = raw.created_timestamp,
        };
    }
};

pub const FeedUpdate = struct {
    etag_or_last_modified: ?[]const u8 = null,
    update_interval: i64 = @import("./app_config.zig").update_interval,
};

pub const ContentType = enum {
    rss,
    atom,
    xml,
    html,

    pub fn fromString(raw: []const u8) ?@This() {
        var iter = mem.splitScalar(u8, raw, ';');
        const input = iter.first();
        const index_split = mem.indexOfScalar(u8, input, '/')
            orelse mem.indexOf(u8, input, "&#43;")
            orelse return null;

        const value_start = input[0..index_split];
        const extra: u8 = if (input[index_split] == '/') 1 else 5;
        const start = index_split + extra;
        const value_end = input[start..];
        if (mem.eql(u8, "application", value_start)) {
            if (mem.eql(u8, "atom+xml", value_end)) {
                return .atom;
            } else if (mem.eql(u8, "rss+xml", value_end)) {
                return .xml;
            }
        } else if (mem.eql(u8, "text", value_start)) {
            if (mem.eql(u8, "html", value_end)) {
                return .html;
            } else if (mem.eql(u8, "xml", value_end)) {
                return .xml;
            }
        }
        return null;
    }
};

pub const FeedToUpdate = struct {
    feed_id: Feed.ID,
    feed_url: std.Uri,
    etag_or_last_modified: ?[]const u8 = null,
    latest_item_id: ?[]const u8 = null,
    latest_item_link: ?[]const u8 = null,
    latest_updated_timestamp: ?i64 = null,

    pub const Raw = struct { 
        feed_id: u64,
        feed_url: []const u8,
        etag_or_last_modified: ?[]const u8 = null,
        latest_item_id: ?[]const u8 = null,
        latest_item_link: ?[]const u8 = null,
        latest_updated_timestamp: ?i64 = null,
    };

    pub fn from_raw(raw: Raw) !FeedToUpdate {
        return .{
            .feed_id = @enumFromInt(raw.feed_id),
            .feed_url = try std.Uri.parse(raw.feed_url),
            .etag_or_last_modified = raw.etag_or_last_modified,
            .latest_item_id = raw.latest_item_id,
            .latest_item_link = raw.latest_item_link,
            .latest_updated_timestamp = raw.latest_updated_timestamp,
        };
    }
};

pub const Icon = struct {
    url: UriWrapper,
    data: []const u8,
    etag_or_last_modified_or_hash: []const u8,

    pub fn init(uri: std.Uri, data: []const u8, etag_or_last_modified: ?[]const u8) @This() {
        return .{
            .url = .{ .value = uri},
            .data = data, 
            .etag_or_last_modified_or_hash = content_cache_value(data, etag_or_last_modified),
        };
    }

    pub fn init_if_data(uri: std.Uri, data: []const u8, etag_or_last_modified: ?[]const u8) ?@This() {
        if (!util.is_data(data)) {
            return null;
        }

        return init(uri, data, etag_or_last_modified);
    }


    // Hashed values start with 'hash'
    pub const hash_start = "hash";
    pub const last_modified_start = "last";
    pub const u64_hex_max_length: u16 = 16;
    const max_start = @max(hash_start.len, last_modified_start.len);
    // Hash format: prefix + last-modified utc hex value (i64) + '-' + content hash
    var hash_buf: [max_start + 1 + u64_hex_max_length * 2]u8 = undefined;
    fn content_cache_value(data: []const u8, etag_or_last_modified: ?[]const u8) []const u8 {
        if (etag_or_last_modified) |val| {
            // Is etag
            if (val.len >= 2 and
                (val[0] == '"' or (val[0] == 'W' and val[1] == '/'))
            ) {
                return val;
            }
        }

        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, data, .Deep);
        const val = hasher.final();

        const prefix, const date = blk: {
            const parse_date = @import("feed_types.zig").RssDateTime.parse;
            if (etag_or_last_modified) |raw| if (parse_date(raw)) |date_utc|{
                break :blk .{last_modified_start, date_utc};
            } else |err| {
                std.log.warn("Failed to parse date '{s}'. Error: {}", .{raw, err});
            };
            break :blk .{hash_start, 0};
        };
        const hash_in_hex = std.fmt.bufPrint(&hash_buf, "{s}{x}-{x}", .{prefix, date, val}) catch |err| {
            std.log.err("Failed to print hashed value in hexdecimal. Error: {}", .{err});
            // This should not happen because buffer has enough space
            unreachable;
        };
      
        return hash_in_hex;
    }
};

pub const FeedOptions = struct {
    body: []const u8 = "",
    content_type: ?ContentType = null,
    feed_updates: FeedUpdate = .{},
    feed_url: std.Uri = .{.scheme = ""},
    title: ?[]const u8 = null,
    icon: ?Icon = null,
};

pub const IconRender = struct {
    icon_id: ID,
    icon_url: std.Uri,
    icon_data: []const u8,
    etag_or_last_modified_or_hash: []const u8,

    pub const ID = SqliteId;

    pub const DB = struct {
        icon_id: ID,
        icon_url: []const u8,
        icon_data: @import("fridge").Blob,
        etag_or_last_modified_or_hash: []const u8,
    };

    pub fn from_raw(raw: DB) !@This() {
        return .{
            .icon_id = raw.icon_id,
            .icon_url = try std.Uri.parse(raw.icon_url),
            .icon_data = .{ .bytes = raw.icon_data },
            .etag_or_last_modified_or_hash = raw.etag_or_last_modified_or_hash,
        };
    }

    pub fn is_data(self: *const @This()) bool {
        return mem.eql(u8, self.icon_url.scheme, "data");
    }
};
