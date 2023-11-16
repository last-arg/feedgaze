const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const testing = std.testing;
const print = std.debug.print;
const expect = testing.expect;
const expectEqual = std.testing.expectEqual;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const xml = @import("xml");
const http = @import("http.zig");
const datetime = @import("datetime").datetime;
const Datetime = datetime.Datetime;
const timezones = @import("datetime").timezones;
const l = std.log;
const expectEqualStrings = std.testing.expectEqualStrings;
pub const Feed = @import("feed.zig").Feed;

// TODO: Might want to increase 'max_title_len' value from 50. When it is
// twitter(nitter) feed I would want more than 50 characters (would want
// all the tweet text).At the moment it isn't a problem because nitter feed
// is an atom feed and atom feeds have to have a title (don't limit title length)
//
// This is only applied to description/text if there is no title.
// Used in Rss and Json feed where title is optional and description/text
// is used as fallback.
const max_title_len = 50;

pub const Html = struct {
    pub const Page = struct {
        title: ?[]const u8 = null,
        links: []Link,
    };

    pub const Link = struct {
        href: []const u8,
        media_type: MediaType = .unknown,
        title: ?[]const u8 = null,
    };

    const Tag = enum {
        none,
        title,
        link_or_a,
    };

    pub const MediaType = enum {
        atom,
        rss,
        unknown,

        pub fn toString(media_type: MediaType) []const u8 {
            return switch (media_type) {
                .atom => "Atom",
                .rss => "RSS",
                .unknown => "Unknown",
            };
        }

        pub fn toMimetype(media_type: MediaType) []const u8 {
            return switch (media_type) {
                .atom => "application/atom+xml",
                .rss => "application/rss+xml",
                .unknown => "Unknown",
            };
        }
    };

    pub fn mediaTypeToString(mt: MediaType) []const u8 {
        var name = @tagName(mt);
        return name;
    }

    pub fn parseLinks(allocator: Allocator, contents_const: []const u8) !Page {
        var contents = contents_const;
        var links = ArrayList(Link).init(allocator);
        defer links.deinit();

        var page_title: ?[]const u8 = null;

        const title_elem = "title>";
        // Seach for 'title' element
        while (mem.indexOfScalar(u8, contents, '<')) |start_index| {
            contents = contents[start_index + 1 ..];
            if (ascii.startsWithIgnoreCase(contents, title_elem)) {
                contents = contents[title_elem.len..];
                const title_end_index = mem.indexOfAny(u8, contents, "</") orelse break;
                page_title = contents[0..title_end_index];
                break;
            } else if (mem.startsWith(u8, contents, "!--")) {
                if (mem.indexOf(u8, contents, "-->")) |comment_end_index| {
                    // skip comments
                    contents = contents[comment_end_index + 3 ..];
                    continue;
                } else break;
            }
            const end_index = mem.indexOfScalar(u8, contents, '>') orelse break;
            contents = contents[end_index..];
        }

        var link_rel: ?[]const u8 = null;
        var link_type: ?[]const u8 = null;
        var link_title: ?[]const u8 = null;
        var link_href: ?[]const u8 = null;

        const link_elem = "link ";
        const a_elem = "a ";

        contents = contents_const;
        // Seach for 'a' or 'link' html elements
        while (mem.indexOfScalar(u8, contents, '<')) |start_index| {
            contents = contents[start_index + 1 ..];
            if (contents[0] == '/') {
                if (mem.indexOfScalar(u8, contents, '>')) |end_index| {
                    contents = contents[end_index + 1 ..];
                    continue;
                } else break;
            } else if (mem.startsWith(u8, contents, "!--")) {
                if (mem.indexOf(u8, contents, "-->")) |comment_end_index| {
                    // skip comments
                    contents = contents[comment_end_index + 3 ..];
                    continue;
                } else break;
            }

            // Check for links
            const is_tag_a = ascii.startsWithIgnoreCase(contents, a_elem);
            const is_tag_link = ascii.startsWithIgnoreCase(contents, link_elem);
            if (!is_tag_a and !is_tag_link) {
                if (mem.indexOfScalar(u8, contents, '>')) |end_index| {
                    contents = contents[end_index + 1 ..];
                    continue;
                } else break;
            }
            const start = if (is_tag_a) a_elem.len else link_elem.len;

            var key: []const u8 = "";
            var value: []const u8 = "";
            contents = mem.trimLeft(u8, contents[start..], &ascii.spaces);
            const end_index = mem.indexOfScalar(u8, contents, '>') orelse break;
            if (end_index == 0) continue;

            var elem_attrs = contents[0..end_index];
            while (elem_attrs.len > 0) {
                const eql_index = mem.indexOfScalar(u8, elem_attrs, '=') orelse break;
                key = mem.trimLeft(u8, elem_attrs[0..eql_index], &ascii.spaces);
                elem_attrs = elem_attrs[eql_index + 1 ..];
                const end_char = blk: {
                    const next_char = elem_attrs[0];
                    if (next_char == '\'' or next_char == '"') {
                        break :blk next_char;
                    }
                    break :blk ' ';
                };
                if (end_char != ' ') {
                    elem_attrs = elem_attrs[1..];
                }
                const elem_end_index = mem.indexOfScalar(u8, elem_attrs, end_char) orelse elem_attrs.len;
                value = mem.trim(u8, elem_attrs[0..elem_end_index], &[_]u8{end_char});
                elem_attrs = elem_attrs[elem_end_index..];
                if (end_char != ' ') {
                    elem_attrs = elem_attrs[1..];
                }

                if (mem.eql(u8, "rel", key)) {
                    link_rel = value;
                } else if (mem.eql(u8, "type", key)) {
                    link_type = value;
                } else if (mem.eql(u8, "title", key)) {
                    link_title = value;
                } else if (mem.eql(u8, "href", key)) {
                    link_href = value;
                }
            }

            const has_link = blk: {
                if (link_href) |href| {
                    for (links.items) |link| {
                        if (mem.eql(u8, link.href, href) and
                            link.media_type != .unknown and
                            link_type != null and
                            mem.eql(u8, link.media_type.toMimetype(), link_type.?))
                        {
                            break :blk true;
                        }
                    }
                }
                break :blk false;
            };

            if (!has_link) {
                if (makeLink(link_rel, link_type, link_href, link_title)) |link| {
                    try links.append(link);
                }
            }

            link_rel = null;
            link_type = null;
            link_title = null;
            link_href = null;

            contents = contents[end_index..];
        }

        return Page{
            .title = page_title,
            .links = links.toOwnedSlice(),
        };
    }

    fn makeLink(
        rel: ?[]const u8,
        type_: ?[]const u8,
        href: ?[]const u8,
        title: ?[]const u8,
    ) ?Link {
        const valid_rel = rel != null and mem.eql(u8, "alternate", rel.?);
        const valid_type = type_ != null;

        if (valid_rel and valid_type) {
            if (href) |link_href| {
                const media_type = blk: {
                    if (mem.eql(u8, "application/rss+xml", type_.?)) {
                        break :blk MediaType.rss;
                    } else if (mem.eql(u8, "application/atom+xml", type_.?)) {
                        break :blk MediaType.atom;
                    }
                    break :blk MediaType.unknown;
                };
                return Link{
                    .href = link_href,
                    .title = title,
                    .media_type = media_type,
                };
            }
        }

        return null;
    }
};

test "Html.parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    {
        // Test duplicate link
        const html = @embedFile("many-links.html");
        const page = try Html.parseLinks(allocator, html);
        try expectEqualStrings(page.title.?, "Parse Feed Links");
        try expectEqual(@as(usize, 5), page.links.len);
        try expectEqual(Html.MediaType.rss, page.links[0].media_type);
        try expectEqual(Html.MediaType.unknown, page.links[1].media_type);
        try expectEqual(Html.MediaType.atom, page.links[2].media_type);
    }
}

pub fn printFeedItems(items: []Feed.Item) void {
    for (items) |item| {
        print("  title: {s}\n", .{item.title});
        if (item.id) |val| print("  id: {s}\n", .{val});
        if (item.link) |val| print("  link: {s}\n", .{val});
        if (item.updated_raw) |val| print("  updated_raw: {s}\n", .{val});
        if (item.updated_timestamp) |val| print("  updated_timestamp: {d}\n", .{val});
        print("\n", .{});
    }
}

pub fn printFeed(feed: Feed) void {
    print("title: {s}\n", .{feed.title});
    if (feed.id) |id| print("id: {s}\n", .{id});
    if (feed.updated_raw) |val| print("updated_raw: {s}\n", .{val});
    if (feed.updated_timestamp) |val| print("updated_timestamp: {d}\n", .{val});
    if (feed.link) |val| print("link: {s}\n", .{val});
    print("items [{d}]:\n", .{feed.items.len});
    printFeedItems(feed.items);
    print("\n", .{});
}

pub const Atom = struct {
    const State = enum {
        feed,
        entry,
    };

    const Field = enum {
        title,
        link,
        id,
        updated,
        published,
        ignore,
    };

    // Atom feed parsing:
    // https://tools.ietf.org/html/rfc4287
    // https://validator.w3.org/feed/docs/atom.html
    pub fn parse(arena: *std.heap.ArenaAllocator, contents: []const u8) !Feed {
        var entries = try ArrayList(Feed.Item).initCapacity(arena.allocator(), 10);
        defer entries.deinit();

        var state: State = .feed;
        var field: Field = .ignore;

        var feed_title: ?[]const u8 = null;
        var feed_date_raw: ?[]const u8 = null;
        var feed_link: ?[]const u8 = null;
        var feed_link_rel: []const u8 = "alternate";
        var feed_link_href: ?[]const u8 = null;

        var title: ?[]const u8 = null;
        var id: ?[]const u8 = null;
        var updated_raw: ?[]const u8 = null;
        var published_raw: ?[]const u8 = null;
        var link_rel: []const u8 = "alternate";
        var link_href: ?[]const u8 = null;

        var xml_parser = xml.Parser.init(contents);
        while (xml_parser.next()) |event| {
            switch (event) {
                .open_tag => |tag| {
                    // warn("open_tag: {s}\n", .{tag});
                    if (mem.eql(u8, "entry", tag)) {
                        state = .entry;
                        link_rel = "alternate";
                        link_href = null;
                        title = null;
                        id = null;
                        updated_raw = null;
                    } else if (mem.eql(u8, "link", tag)) {
                        field = .link;
                    } else if (mem.eql(u8, "id", tag)) {
                        field = .id;
                    } else if (mem.eql(u8, "updated", tag)) {
                        field = .updated;
                    } else if (mem.eql(u8, "title", tag)) {
                        field = .title;
                    }
                },
                .close_tag => |tag| {
                    // warn("close_tag: {s}\n", .{tag});
                    switch (state) {
                        .feed => {
                            if (field == .link and mem.eql(u8, "self", feed_link_rel)) {
                                feed_link = feed_link_href;
                            }
                        },
                        .entry => {
                            if (mem.eql(u8, "entry", tag)) {
                                const published_timestamp = blk: {
                                    if (published_raw) |date| {
                                        const date_utc = try parseDateToUtc(date);
                                        break :blk @as(i64, @intFromFloat(date_utc.toSeconds()));
                                    }
                                    if (updated_raw) |date| {
                                        const date_utc = try parseDateToUtc(date);
                                        break :blk @as(i64, @intFromFloat(date_utc.toSeconds()));
                                    }
                                    break :blk null;
                                };
                                const entry = Feed.Item{
                                    .title = title orelse return error.InvalidAtomFeed,
                                    .id = id,
                                    .link = link_href,
                                    .updated_raw = published_raw orelse updated_raw,
                                    .updated_timestamp = published_timestamp,
                                };
                                try entries.append(entry);
                                state = .feed;
                            }
                        },
                    }
                    field = .ignore;
                },
                .attribute => |attr| {
                    // warn("attribute\n", .{});
                    // warn("\tname: {s}\n", .{attr.name});
                    // warn("\traw_value: {s}\n", .{attr.raw_value});
                    switch (state) {
                        .feed => {
                            if (mem.eql(u8, "rel", attr.name)) {
                                feed_link_rel = attr.raw_value;
                            } else if (mem.eql(u8, "href", attr.name)) {
                                feed_link_href = attr.raw_value;
                            }
                        },
                        .entry => {
                            if (mem.eql(u8, "rel", attr.name)) {
                                link_rel = attr.raw_value;
                            } else if (mem.eql(u8, "href", attr.name)) {
                                link_href = attr.raw_value;
                            }
                        },
                    }
                },
                .comment => |_| {
                    // warn("comment: {s}\n", .{str});
                },
                .processing_instruction => |_| {
                    // warn("processing_instruction: {s}\n", .{str});
                },
                .character_data => |value| {
                    switch (state) {
                        .feed => {
                            switch (field) {
                                .title => {
                                    feed_title = try xmlCharacterData(&xml_parser, arena.allocator(), value, "title");
                                    field = .ignore;
                                },
                                .updated => {
                                    feed_date_raw = value;
                                },
                                .ignore, .link, .published, .id => {},
                            }
                        },
                        .entry => {
                            switch (field) {
                                .id => {
                                    id = value;
                                },
                                .title => {
                                    title = try xmlCharacterData(&xml_parser, arena.allocator(), value, "title");
                                    field = .ignore;
                                },
                                .updated => {
                                    updated_raw = value;
                                },
                                .published => {
                                    published_raw = value;
                                },
                                .ignore, .link => {},
                            }
                        },
                    }
                },
            }
        }

        var updated_timestamp: ?i64 = null;
        if (feed_date_raw) |date| {
            const date_utc = try parseDateToUtc(date);
            updated_timestamp = @as(i64, @intFromFloat(date_utc.toSeconds()));
        } else if (entries.items.len > 0 and entries.items[0].updated_raw != null) {
            var tmp_timestamp: i64 = entries.items[0].updated_timestamp.?;
            for (entries.items[1..]) |item| {
                if (item.updated_timestamp != null and
                    item.updated_timestamp.? > tmp_timestamp)
                {
                    feed_date_raw = item.updated_raw;
                    updated_timestamp = item.updated_timestamp;
                }
            }
        }

        var result = Feed{
            .title = feed_title orelse return error.InvalidAtomFeed,
            .link = feed_link,
            .updated_raw = feed_date_raw,
            .updated_timestamp = updated_timestamp,
            .items = try entries.toOwnedSlice(),
        };

        return result;
    }

    fn xmlCharacterData(
        xml_parser: *xml.Parser,
        allocator: Allocator,
        start_value: []const u8,
        close_tag: []const u8,
    ) ![]const u8 {
        var values = try ArrayList(u8).initCapacity(allocator, start_value.len);
        defer values.deinit();
        {
            var iter = mem.split(u8, start_value, "\n");
            const first = iter.next() orelse unreachable;
            values.appendSliceAssumeCapacity(first);
            while (iter.next()) |value| {
                const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;
                values.appendAssumeCapacity(' ');
                values.appendSliceAssumeCapacity(trimmed);
            }
        }

        while (xml_parser.next()) |item_event| {
            switch (item_event) {
                .close_tag => |tag| if (mem.eql(u8, close_tag, tag)) break,
                .character_data => |title_value| {
                    try values.ensureTotalCapacity(values.items.len + title_value.len);
                    var iter = mem.split(u8, title_value, "\n");
                    const first = iter.next() orelse unreachable;
                    values.appendSliceAssumeCapacity(first);
                    while (iter.next()) |value| {
                        const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                        if (trimmed.len == 0) continue;
                        values.appendAssumeCapacity(' ');
                        values.appendSliceAssumeCapacity(trimmed);
                    }
                },
                else => std.debug.panic("Xml(Atom): Failed to parse {s}'s value\n", .{close_tag}),
            }
        }

        return values.toOwnedSlice();
    }

    // Atom updated_timestamp: http://www.faqs.org/rfcs/rfc3339.html
    pub fn parseDateToUtc(raw: []const u8) !Datetime {
        const year = try fmt.parseUnsigned(u32, raw[0..4], 10);
        const month = try fmt.parseUnsigned(u32, raw[5..7], 10);
        const day = try fmt.parseUnsigned(u32, raw[8..10], 10);
        const hour = try fmt.parseUnsigned(u32, raw[11..13], 10);
        const minute = try fmt.parseUnsigned(u32, raw[14..16], 10);
        const second = try fmt.parseUnsigned(u32, raw[17..19], 10);

        const zone_start = mem.lastIndexOfAny(u8, raw, "Z+-") orelse return error.InvalidAtomDate;

        const nano_sec: u32 = blk: {
            if (zone_start == 19) {
                break :blk 0;
            }
            const ms_raw = raw[20..zone_start];
            var ms = try fmt.parseUnsigned(u32, ms_raw, 10);
            if (ms_raw.len == 1) {
                ms *= 100;
            } else if (ms_raw.len == 2) {
                ms *= 10;
            }
            break :blk ms * std.time.ns_per_ms;
        };

        var result = try Datetime.create(year, month, day, hour, minute, second, nano_sec, null);

        if (raw[zone_start] != 'Z') {
            const tz = raw[zone_start + 1 ..];
            const tz_hour = try fmt.parseUnsigned(u16, tz[0..2], 10);
            const tz_minute = try fmt.parseUnsigned(u16, tz[3..5], 10);
            var total_minutes: i32 = (tz_hour * 60) + tz_minute;
            const sym = raw[zone_start];
            if (sym == '+') {
                total_minutes *= -1;
            }
            result = result.shiftMinutes(total_minutes);
        }

        return result;
    }
};

test "Atom.parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const contents = @embedFile("atom.xml");
    const result = try Atom.parse(&arena, contents);
    try testing.expectEqualStrings("Example Feed", result.title);
    try testing.expectEqualStrings("http://example.org/feed/", result.link.?);
    try testing.expectEqualStrings("2012-12-13T18:30:02Z", result.updated_raw.?);

    try expect(1355423402 == result.updated_timestamp.?);
    try expect(null != result.items[0].updated_raw);

    try expect(2 == result.items.len);

    {
        const item = result.items[0];
        try testing.expectEqualStrings("Atom-Powered Robots Run Amok", item.title);
        try testing.expectEqualStrings("http://example.org/2003/12/13/atom03", item.link.?);
        try testing.expectEqualStrings("2008-11-13T18:30:02Z", item.updated_raw.?);
    }

    {
        const item = result.items[1];
        try testing.expectEqualStrings("Entry one's 1", item.title);
        try testing.expectEqualStrings("http://example.org/2008/12/13/entry-1", item.link.?);
        try testing.expectEqualStrings("2005-12-13T18:30:02Z", item.updated_raw.?);
    }
}

test "Atom.parseDateToUtc" {
    l.warn("\n", .{});
    {
        const date_raw = "2003-12-13T18:30:02Z";
        const dt = try Atom.parseDateToUtc(date_raw);
        try expect(2003 == dt.date.year);
        try expect(12 == dt.date.month);
        try expect(13 == dt.date.day);
        try expect(18 == dt.time.hour);
        try expect(30 == dt.time.minute);
        try expect(2 == dt.time.second);
        try expect(0 == dt.time.nanosecond);
        try expect(0 == dt.zone.offset);
    }
    {
        const date_raw = "2003-12-13T18:30:02.25Z";
        const dt = try Atom.parseDateToUtc(date_raw);
        try expect(2003 == dt.date.year);
        try expect(12 == dt.date.month);
        try expect(13 == dt.date.day);
        try expect(18 == dt.time.hour);
        try expect(30 == dt.time.minute);
        try expect(2 == dt.time.second);
        try expect(250000000 == dt.time.nanosecond);
        try expect(0 == dt.zone.offset);
    }
    {
        const date_raw = "2003-12-13T18:30:02+01:00";
        const dt = try Atom.parseDateToUtc(date_raw);
        try expect(2003 == dt.date.year);
        try expect(12 == dt.date.month);
        try expect(13 == dt.date.day);
        try expect(17 == dt.time.hour);
        try expect(30 == dt.time.minute);
        try expect(2 == dt.time.second);
        try expect(0 == dt.time.nanosecond);
        try expect(0 == dt.zone.offset);
    }
    {
        const date_raw = "2003-12-13T18:30:02.25+01:00";
        const dt = try Atom.parseDateToUtc(date_raw);
        try expect(2003 == dt.date.year);
        try expect(12 == dt.date.month);
        try expect(13 == dt.date.day);
        try expect(17 == dt.time.hour);
        try expect(30 == dt.time.minute);
        try expect(2 == dt.time.second);
        try expect(250000000 == dt.time.nanosecond);
        try expect(0 == dt.zone.offset);
    }
}

pub const Rss = struct {
    const State = enum {
        channel,
        item,
    };

    const ChannelField = enum {
        title,
        link,
        pub_date,
        last_build_date,
        ttl,
        sy_update_period,
        sy_update_frequency,
        _ignore,
    };

    const ItemField = enum {
        title,
        description,
        link,
        pub_date,
        guid,
        _ignore,
    };

    const SyUpdatePeriod = enum {
        hourly,
        daily,
        weekly,
        monthly,
        yearly,

        pub fn fromString(value: []const u8) ?@This() {
            return std.meta.stringToEnum(@This(), value);
        }

        pub fn toSeconds(self: @This()) u32 {
            return switch (self) {
                .hourly => 3600,
                .daily => 86400,
                .weekly => 604800,
                .monthly => 2629800,
                .yearly => 31536000,
            };
        }
    };

    pub fn parse(arena: *std.heap.ArenaAllocator, contents: []const u8) !Feed {
        var items = try ArrayList(Feed.Item).initCapacity(arena.allocator(), 10);
        defer items.deinit();

        var state: State = .channel;
        var channel_field: ChannelField = ._ignore;
        var item_field: ItemField = ._ignore;

        var item_title: ?[]const u8 = null;
        var item_description: ?[]const u8 = null;
        var item_link: ?[]const u8 = null;
        var item_guid: ?[]const u8 = null;
        var item_pub_date: ?[]const u8 = null;

        var feed_title: ?[]const u8 = null;
        var feed_link: ?[]const u8 = null;
        var feed_pub_date: ?[]const u8 = null;
        var feed_build_date: ?[]const u8 = null;
        var feed_ttl: ?u32 = null;
        var sy_update_period: ?SyUpdatePeriod = null;
        var sy_update_frequency: u32 = 1;

        var xml_parser = xml.Parser.init(contents);
        while (xml_parser.next()) |event| {
            switch (event) {
                .open_tag => |tag| {
                    // warn("open_tag: {s}\n", .{tag});
                    switch (state) {
                        .channel => {
                            if (mem.eql(u8, "title", tag)) {
                                channel_field = .title;
                            } else if (mem.eql(u8, "link", tag)) {
                                channel_field = .link;
                            } else if (mem.eql(u8, "pubDate", tag)) {
                                channel_field = .pub_date;
                            } else if (mem.eql(u8, "lastBuildDate", tag)) {
                                channel_field = .last_build_date;
                            } else if (mem.eql(u8, "ttl", tag)) {
                                channel_field = .ttl;
                            } else if (mem.eql(u8, "sy:updatePeriod", tag)) {
                                channel_field = .sy_update_period;
                            } else if (mem.eql(u8, "sy:updateFrequency", tag)) {
                                channel_field = .sy_update_frequency;
                            } else if (mem.eql(u8, "item", tag)) {
                                state = .item;
                                item_title = null;
                                item_description = null;
                                item_guid = null;
                                item_link = null;
                                item_pub_date = null;
                            } else {
                                channel_field = ._ignore;
                            }
                        },
                        .item => {
                            if (mem.eql(u8, "title", tag)) {
                                item_field = .title;
                            } else if (mem.eql(u8, "link", tag)) {
                                item_field = .link;
                            } else if (mem.eql(u8, "pubDate", tag)) {
                                item_field = .pub_date;
                            } else if (mem.eql(u8, "description", tag)) {
                                item_field = .description;
                            } else if (mem.eql(u8, "guid", tag)) {
                                item_field = .guid;
                            } else {
                                item_field = ._ignore;
                            }
                        },
                    }
                },
                .close_tag => |tag| {
                    // warn("close_tag: {s}\n", .{str});
                    if (mem.eql(u8, "item", tag)) {
                        const updated_timestamp = blk: {
                            if (item_pub_date) |date| {
                                const date_utc = try parseDateToUtc(date);
                                break :blk @as(i64, @intFromFloat(date_utc.toSeconds()));
                            }
                            break :blk null;
                        };
                        const item = Feed.Item{
                            .title = item_title orelse item_description orelse return error.InvalidRssFeed,
                            .id = item_guid,
                            .link = item_link,
                            .updated_raw = item_pub_date,
                            .updated_timestamp = updated_timestamp,
                        };
                        try items.append(item);

                        state = .channel;
                    }
                },
                .attribute => |_| {
                    // warn("attribute\n", .{});
                    // warn("\tname: {s}\n", .{attr.name});
                    // warn("\traw_value: {s}\n", .{attr.raw_value});
                },
                .comment => |_| {
                    // warn("comment: {s}\n", .{str});
                },
                .processing_instruction => |_| {
                    // warn("processing_instruction: {s}\n", .{str});
                },
                .character_data => |value| {
                    // warn("character_data: {s}\n", .{value});
                    switch (state) {
                        .channel => {
                            switch (channel_field) {
                                .title => {
                                    feed_title = try xmlCharacterData(&xml_parser, arena.allocator(), value, "title");
                                    channel_field = ._ignore;
                                },
                                .link => {
                                    feed_link = value;
                                },
                                .pub_date => {
                                    feed_pub_date = value;
                                },
                                .last_build_date => {
                                    feed_build_date = value;
                                },
                                .ttl => {
                                    feed_ttl = try std.fmt.parseInt(u32, value, 10);
                                },
                                .sy_update_period => {
                                    if (SyUpdatePeriod.fromString(value)) |val| {
                                        sy_update_period = val;
                                    }
                                },
                                .sy_update_frequency => {
                                    sy_update_frequency = try std.fmt.parseInt(u32, mem.trim(u8, value, &ascii.whitespace), 10);
                                },
                                ._ignore => {},
                            }
                        },
                        .item => {
                            switch (item_field) {
                                .title => {
                                    item_title = try xmlCharacterData(&xml_parser, arena.allocator(), value, "title");
                                    item_field = ._ignore;
                                },
                                .link => {
                                    item_link = value;
                                },
                                .pub_date => {
                                    item_pub_date = value;
                                },
                                .guid => {
                                    item_guid = value;
                                },
                                .description => {
                                    item_description = try xmlCharacterData(&xml_parser, arena.allocator(), value, "description");
                                    const len = @min(item_description.?.len, max_title_len);
                                    item_description = item_description.?[0..len];
                                },
                                ._ignore => {},
                            }
                        },
                    }
                },
            }
        }

        var date_raw = feed_pub_date orelse feed_build_date;
        var updated_timestamp: ?i64 = null;
        if (date_raw) |date| {
            const date_utc = try parseDateToUtc(date);
            updated_timestamp = @as(i64, @intFromFloat(date_utc.toSeconds()));
        } else if (items.items.len > 0 and items.items[0].updated_raw != null) {
            var tmp_timestamp: i64 = items.items[0].updated_timestamp.?;
            for (items.items[1..]) |item| {
                if (item.updated_timestamp != null and
                    item.updated_timestamp.? > tmp_timestamp)
                {
                    date_raw = item.updated_raw;
                    updated_timestamp = item.updated_timestamp;
                }
            }
        }

        const interval = blk: {
            if (sy_update_period) |update_period| {
                break :blk update_period.toSeconds() * sy_update_frequency;
            }
            if (feed_ttl) |ttl| {
                break :blk ttl * 60;
            }
            break :blk null;
        };

        const result = Feed{
            .title = feed_title orelse return error.InvalidRssFeed,
            .link = feed_link,
            .updated_raw = date_raw,
            .items = try items.toOwnedSlice(),
            .updated_timestamp = updated_timestamp,
            .interval_sec = interval,
        };

        return result;
    }

    fn xmlCharacterData(
        xml_parser: *xml.Parser,
        allocator: Allocator,
        start_value: []const u8,
        close_tag: []const u8,
    ) ![]const u8 {
        var values = try ArrayList(u8).initCapacity(allocator, start_value.len);
        defer values.deinit();
        {
            var iter = mem.split(u8, start_value, "\n");
            const first = iter.next() orelse unreachable;
            values.appendSliceAssumeCapacity(first);
            while (iter.next()) |value| {
                const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;
                values.appendAssumeCapacity(' ');
                values.appendSliceAssumeCapacity(trimmed);
            }
        }

        while (xml_parser.next()) |item_event| {
            switch (item_event) {
                .close_tag => |tag| if (mem.eql(u8, close_tag, tag)) break,
                .character_data => |title_value| {
                    try values.ensureTotalCapacity(values.items.len + title_value.len);
                    var iter = mem.split(u8, title_value, "\n");
                    const first = iter.next() orelse unreachable;
                    values.appendSliceAssumeCapacity(first);
                    while (iter.next()) |value| {
                        const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                        if (trimmed.len == 0) continue;
                        values.appendAssumeCapacity(' ');
                        values.appendSliceAssumeCapacity(trimmed);
                    }
                },
                else => std.debug.panic("Xml(RSS): Failed to parse {s}'s value\n", .{close_tag}),
            }
        }

        return values.toOwnedSlice();
    }

    pub fn pubDateToTimestamp(str: []const u8) !i64 {
        const dt = try Rss.parseDateToUtc(str);
        const date_time_gmt = dt.shiftTimezone(&timezones.GMT);
        return @as(i64, @intCast(date_time_gmt.toTimestamp()));
    }

    // Isn't the same as Datetime.parseModifiedSince(). In HTTP header timezone is always GMT.
    // In Rss spec timezones might not be GMT.
    pub fn parseDateToUtc(str: []const u8) !Datetime {
        var iter = mem.split(u8, str, " ");

        // Skip: don't care about day of week
        _ = iter.next();

        // Day of month
        const day_str = iter.next() orelse return error.InvalidPubDate;
        const day = try fmt.parseInt(u8, day_str, 10);

        // month
        const month_str = iter.next() orelse return error.InvalidPubDate;
        const month = @intFromEnum(try datetime.Month.parseAbbr(month_str));

        // year
        // year can also be 2 digits
        const year_str = iter.next() orelse return error.InvalidPubDate;
        const year = blk: {
            const y = try fmt.parseInt(u16, year_str, 10);
            if (y < 100) {
                // If year is 2 numbers long
                const last_two_digits = datetime.Date.now().year - 2000;
                if (y <= last_two_digits) {
                    break :blk 2000 + y;
                }
                break :blk 1900 + y;
            }

            break :blk y;
        };

        // time
        const time_str = iter.next() orelse return error.InvalidPubDate;
        var time_iter = mem.split(u8, time_str, ":");
        // time: hour
        const hour_str = time_iter.next() orelse return error.InvalidPubDate;
        const hour = try fmt.parseInt(u8, hour_str, 10);
        // time: minute
        const minute_str = time_iter.next() orelse return error.InvalidPubDate;
        const minute = try fmt.parseInt(u8, minute_str, 10);
        // time: second
        const second_str = time_iter.next() orelse return error.InvalidPubDate;
        const second = try fmt.parseInt(u8, second_str, 10);

        // Timezone default to UTC
        var result = try Datetime.create(year, month, day, hour, minute, second, 0, null);

        // timezone
        // NOTE: dates with timezone format +/-NNNN will be turned into UTC
        const tz_str = iter.next() orelse return error.InvalidPubDate;
        if (tz_str[0] == '+' or tz_str[0] == '-') {
            const tz_hours = try fmt.parseInt(i16, tz_str[1..3], 10);
            const tz_minutes = try fmt.parseInt(i16, tz_str[3..5], 10);
            var total_minutes = (tz_hours * 60) + tz_minutes;
            if (tz_str[0] == '-') {
                total_minutes = -total_minutes;
            }
            result = result.shiftMinutes(-total_minutes);
        } else {
            result.zone = stringToTimezone(tz_str);
        }

        return result;
    }

    pub fn stringToTimezone(str: []const u8) *const datetime.Timezone {
        // This default case covers UT, GMT and Z timezone values.
        if (mem.eql(u8, "EST", str)) {
            return &timezones.EST;
        } else if (mem.eql(u8, "EDT", str)) {
            return &timezones.America.Anguilla;
        } else if (mem.eql(u8, "CST", str)) {
            return &timezones.CST6CDT;
        } else if (mem.eql(u8, "CDT", str)) {
            return &timezones.US.Eastern;
        } else if (mem.eql(u8, "MST", str)) {
            return &timezones.MST;
        } else if (mem.eql(u8, "MDT", str)) {
            return &timezones.US.Central;
        } else if (mem.eql(u8, "PST", str)) {
            return &timezones.PST8PDT;
        } else if (mem.eql(u8, "PDT", str)) {
            return &timezones.US.Mountain;
        } else if (mem.eql(u8, "A", str)) {
            return &timezones.Atlantic.Cape_Verde;
        } else if (mem.eql(u8, "M", str)) {
            return &timezones.Etc.GMTp12;
        } else if (mem.eql(u8, "N", str)) {
            return &timezones.CET;
        } else if (mem.eql(u8, "Y", str)) {
            return &timezones.NZ;
        }
        return &timezones.UTC;
    }
};

test "Rss.parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const contents = @embedFile("../test/rss2.xml");
    var feed = try Rss.parse(&arena, contents);
    try std.testing.expectEqualStrings("Liftoff News", feed.title);
    try std.testing.expectEqualStrings("http://liftoff.msfc.nasa.gov/", feed.link.?);
    try std.testing.expectEqualStrings("Tue, 10 Jun 2003 04:00:00 +0100", feed.updated_raw.?);
    try expect(1055214000 == feed.updated_timestamp.?);
    try expect(6 == feed.items.len);

    // Description is used as title
    try expect(null != feed.items[0].updated_raw);
    try std.testing.expectEqualStrings("Sky watchers in Europe, Asia, and parts of Alaska ", feed.items[1].title);
}

test "Rss.parseDateToUtc" {
    {
        const date_str = "Tue, 03 Jun 2003 09:39:21 GMT";
        const date = try Rss.parseDateToUtc(date_str);
        try expect(2003 == date.date.year);
        try expect(6 == date.date.month);
        try expect(3 == date.date.day);
        try expect(9 == date.time.hour);
        try expect(39 == date.time.minute);
        try expect(21 == date.time.second);
        try expect(date.zone.offset == 0);
    }

    {
        // dates with timezone format +/-NNNN will be turned into UTC
        const date_str = "Wed, 01 Oct 2002 01:00:00 +0200";
        const date = try Rss.parseDateToUtc(date_str);
        try expect(2002 == date.date.year);
        try expect(9 == date.date.month);
        try expect(30 == date.date.day);
        try expect(23 == date.time.hour);
        try expect(0 == date.time.minute);
        try expect(0 == date.time.second);
        try expect(date.zone.offset == 0);
    }

    {
        // dates with timezone format +/-NNNN will be turned into UTC
        const date_str = "Wed, 01 Oct 2002 01:00:00 -0200";
        const date = try Rss.parseDateToUtc(date_str);
        try expect(2002 == date.date.year);
        try expect(10 == date.date.month);
        try expect(1 == date.date.day);
        try expect(3 == date.time.hour);
        try expect(0 == date.time.minute);
        try expect(0 == date.time.second);
        try expect(date.zone.offset == 0);
    }
}

// Json Feed
// https://www.jsonfeed.org/version/1.1/
pub const Json = struct {
    const json = std.json;
    const JsonFeed = struct {
        version: []const u8, // required
        title: []const u8,
        home_page_url: ?[]const u8 = null, // optional
        items: []Item,

        const Item = struct {
            id: []const u8, // required, can be url
            // If there is no title slice a title from content_text or content_html.
            // Item has to have content_text or content_html field
            title: ?[]const u8 = null, // optional
            content_text: ?[]const u8 = null, // optional
            content_html: ?[]const u8 = null, // optional
            url: ?[]const u8 = null,
            date_published: ?[]const u8 = null,
            date_modified: ?[]const u8 = null,
        };
    };

    pub fn parse(arena: *std.heap.ArenaAllocator, contents: []const u8) !Feed {
        const options = .{ .ignore_unknown_fields = true, .allocator = arena.allocator() };
        var stream = json.TokenStream.init(contents);
        const json_feed = json.parse(JsonFeed, &stream, options) catch |err| {
            switch (err) {
                error.MissingField => l.err("Failed to parse Json. Missing a required field.", .{}),
                else => l.err("Failed to parse Json.", .{}),
            }
            return error.JsonFeedParsingFailed;
        };
        errdefer json.parseFree(JsonFeed, json_feed, options);
        if (!ascii.startsWithIgnoreCase(json_feed.version, "https://jsonfeed.org/version/1")) {
            l.err("Json contains invalid version field value: '{s}'", .{json_feed.version});
            return error.JsonFeedInvalidVersion;
        }

        var new_items = try ArrayList(Feed.Item).initCapacity(arena.allocator(), json_feed.items.len);
        errdefer new_items.deinit();
        for (json_feed.items) |item| {
            const date_str = item.date_published orelse item.date_modified;
            const date_utc = blk: {
                if (date_str) |date| {
                    const date_utc = try parseDateToUtc(date);
                    break :blk @as(i64, @intFromFloat(date_utc.toSeconds()));
                }
                break :blk null;
            };
            const title = item.title orelse blk: {
                const text = (item.content_text orelse item.content_html).?;
                const len = @min(text.len, max_title_len);
                break :blk text[0..len];
            };
            const new_item = Feed.Item{
                .title = title,
                .id = item.id,
                .link = item.url,
                .updated_raw = date_str,
                .updated_timestamp = date_utc,
            };
            new_items.appendAssumeCapacity(new_item);
        }
        return Feed{
            .title = json_feed.title,
            // There are no top-level date fields in json feed
            .link = json_feed.home_page_url,
            .items = new_items.toOwnedSlice(),
        };
    }

    pub fn parseDateToUtc(str: []const u8) !Datetime {
        return try Atom.parseDateToUtc(str);
    }
};

test "Json.parse()" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const contents = @embedFile("json_feed.json");
    var feed = try Json.parse(&arena, contents);

    try expectEqualStrings("My Example Feed", feed.title);
    try expectEqualStrings("https://example.org/", feed.link.?);

    {
        const item = feed.items[0];
        try expectEqualStrings("2", item.id.?);
        try expectEqualStrings("This is a second item.", item.title);
        try expectEqualStrings("https://example.org/second-item", item.link.?);
        try std.testing.expect(null == item.updated_raw);
    }

    {
        const item = feed.items[1];
        try expectEqualStrings("1", item.id.?);
        try expectEqualStrings("<p>Hello, world!</p>", item.title);
        try expectEqualStrings("https://example.org/initial-post", item.link.?);
        try std.testing.expect(null == item.updated_raw);
    }
}

pub fn parse(arena: *std.heap.ArenaAllocator, contents: []const u8) !Feed {
    if (isAtom(contents)) {
        return try Atom.parse(arena, contents);
    } else if (isRss(contents)) {
        return try Rss.parse(arena, contents);
    }
    return error.InvalidFeedContent;
}

pub fn isRss(body: []const u8) bool {
    const rss_str = "<rss";
    var start = ascii.indexOfIgnoreCase(body, rss_str) orelse return false;
    const end = mem.indexOfScalarPos(u8, body, start, '>') orelse return false;
    start += rss_str.len;
    if (ascii.indexOfIgnoreCase(body[start..end], "version=") == null) return false;
    if (ascii.indexOfIgnoreCase(body[end + 1 ..], "<channel") == null) return false;
    return true;
}

pub fn isAtom(body: []const u8) bool {
    const start_str = "<feed";
    var start = ascii.indexOfIgnoreCase(body, start_str) orelse return false;
    const end = mem.indexOfScalarPos(u8, body, start, '>') orelse return false;
    start += start_str.len;
    return ascii.indexOfIgnoreCase(body[start..end], "xmlns=\"http://www.w3.org/2005/Atom\"") != null;
}

test "isRss(), isAtom()" {
    try expect(isRss(@embedFile("rss2.xml")));
    try expect(isAtom(@embedFile("atom.xml")));
}
