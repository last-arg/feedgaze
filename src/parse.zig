const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;
const testing = std.testing;
const expect = testing.expect;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const xml = @import("xml");
const datetime = @import("datetime");
const Datetime = datetime.Datetime;
const timezones = datetime.timezones;
const l = std.log;

// TODO: decode html entities
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
    };

    pub fn mediaTypeToString(mt: MediaType) []const u8 {
        var name = @tagName(mt);
        return name;
    }

    pub fn parseLinks(allocator: *Allocator, contents_const: []const u8) !Page {
        var contents = contents_const;
        var links = ArrayList(Link).init(allocator);
        defer links.deinit();

        var page_title: ?[]const u8 = null;

        const title_elem = "<title>";
        if (ascii.indexOfIgnoreCase(contents, title_elem)) |index| {
            const start = index + title_elem.len;
            if (ascii.indexOfIgnoreCase(contents[start..], "</title>")) |end| {
                page_title = contents[start .. start + end];
            }
        }

        var link_rel: ?[]const u8 = null;
        var link_type: ?[]const u8 = null;
        var link_title: ?[]const u8 = null;
        var link_href: ?[]const u8 = null;

        const link_elem = "<link ";
        const a_elem = "<a ";

        while (ascii.indexOfIgnoreCase(contents, link_elem) orelse
            ascii.indexOfIgnoreCase(contents, a_elem)) |index|
        {
            var key: []const u8 = "";
            var value: []const u8 = "";
            contents = contents[index..];
            const start = blk: {
                if (ascii.startsWithIgnoreCase(contents, a_elem)) {
                    break :blk a_elem.len;
                }
                break :blk link_elem.len;
            };
            contents = contents[start..];
            while (true) {
                // skip whitespace
                contents = mem.trimLeft(u8, contents, &ascii.spaces);
                if (contents[0] == '>') {
                    contents = contents[1..];
                    break;
                } else if (contents[0] == '/') {
                    contents = mem.trimLeft(u8, contents[1..], &ascii.spaces);
                    if (contents[0] == '>') {
                        contents = contents[1..];
                        break;
                    }
                } else if (contents.len == 0) {
                    break;
                }

                const next_eql = mem.indexOfScalar(u8, contents, '=') orelse contents.len;
                const next_space = mem.indexOfAny(u8, contents, &ascii.spaces) orelse contents.len;
                const next_slash = mem.indexOfScalar(u8, contents, '/') orelse contents.len;
                const next_gt = mem.indexOfScalar(u8, contents, '>') orelse contents.len;

                const end = blk: {
                    var smallest = next_space;
                    if (next_slash < smallest) {
                        smallest = next_slash;
                    }
                    if (next_gt < smallest) {
                        smallest = next_gt;
                    }
                    break :blk smallest;
                };

                if (next_eql < end) {
                    key = contents[0..next_eql];
                    contents = contents[next_eql + 1 ..];
                    switch (contents[0]) {
                        '"' => {
                            contents = contents[1..];
                            const value_end = mem.indexOfScalar(u8, contents, '"') orelse break;

                            value = contents[0..value_end];
                            contents = contents[value_end + 1 ..];
                        },
                        '\'' => {
                            contents = contents[1..];
                            const value_end = mem.indexOfScalar(u8, contents, '\'') orelse break;

                            value = contents[0..value_end];
                            contents = contents[value_end + 1 ..];
                        },
                        else => {
                            value = contents[0..end];
                            contents = contents[end + 1 ..];
                        },
                    }
                } else {
                    contents = contents[end + 1 ..];
                    continue;
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

            if (makeLink(link_rel, link_type, link_href, link_title)) |link| {
                try links.append(link);
            }

            link_rel = null;
            link_type = null;
            link_title = null;
            link_href = null;
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

test "parse html links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const html = @embedFile("../test/lobste.rs.html");
    const page = try Html.parseLinks(allocator, html);
    expect(5 == page.links.len);
    expect(Html.MediaType.rss == page.links[0].media_type);
}

// Based on Atom spec/rfc
pub const Feed = struct {
    // Atom: required
    // Rss: required
    title: []const u8,
    // Atom: required
    // Rss: doesn't exits. Use link or feed url location?
    id: ?[]const u8,
    // Atom: updated (required)
    // Rss: pubDate (optional)
    updated_raw: ?[]const u8 = null,
    // TODO: update_utc: i64,
    // Atom: optional
    // Rss: required
    link: ?[]const u8 = null,
    items: []Item,

    pub const Item = struct {
        // Atom: title (required)
        // Rss: must have atleast title or description
        title: []const u8,
        // Atom: id (required)
        // Rss: guid (optional)
        id: ?[]const u8 = null,
        // Atom: id (optional)
        // Rss: guid (optional)
        link: ?[]const u8 = null,
        // Atom: updated (requried)
        // Rss: pubDate (optional)
        updated_raw: ?[]const u8 = null,
    };
};

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
        ignore,
    };

    // text contructs can have type text(default), html, xhtml
    // In case of html and xhtml have to decode
    // TODO: decode text entities

    // Atom feed parsing:
    // https://tools.ietf.org/html/rfc4287
    // https://validator.w3.org/feed/docs/atom.html
    pub fn parse(allocator: *Allocator, contents: []const u8) !Feed {
        var entries = ArrayList(Feed.Item).init(allocator);
        defer entries.deinit();

        var state: State = .feed;
        var field: Field = .ignore;

        var feed_title: ?[]const u8 = null;
        var feed_id: ?[]const u8 = null;
        var feed_date_raw: ?[]const u8 = null;
        var feed_link: ?[]const u8 = null;
        var feed_link_rel: []const u8 = "alternate";
        var feed_link_href: ?[]const u8 = null;

        var title: ?[]const u8 = null;
        var id: ?[]const u8 = null;
        var date_raw: ?[]const u8 = null;
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
                        date_raw = null;
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
                                // TODO: parse date
                                // const date_utc = parseDate(date_raw) catch |_| null;
                                const entry = Feed.Item{
                                    .title = title orelse return error.InvalidAtomFeed,
                                    .id = id,
                                    .link = link_href,
                                    .updated_raw = date_raw,
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
                .comment => |str| {
                    // warn("comment: {s}\n", .{str});
                },
                .processing_instruction => |str| {
                    // warn("processing_instruction: {s}\n", .{str});
                },
                .character_data => |value| {
                    // warn("character_data: {s}\n", .{value});
                    switch (state) {
                        .feed => {
                            switch (field) {
                                .id => {
                                    feed_id = value;
                                },
                                .title => {
                                    feed_title = value;
                                },
                                .updated => {
                                    feed_date_raw = value;
                                },
                                .ignore, .link => {},
                            }
                        },
                        .entry => {
                            switch (field) {
                                .id => {
                                    id = value;
                                },
                                .title => {
                                    title = value;
                                },
                                .updated => {
                                    date_raw = value;
                                },
                                .ignore, .link => {},
                            }
                        },
                    }
                },
            }
        }

        var result = Feed{
            .title = feed_title orelse return error.InvalidAtomFeed,
            .id = feed_id,
            .link = feed_link,
            .updated_raw = feed_date_raw,
            .items = entries.toOwnedSlice(),
        };

        return result;
    }

    // Atom timestamp: http://www.faqs.org/rfcs/rfc3339.html
    // Datetime examples:
    pub fn parseDateToUtc(raw: []const u8) !Datetime {
        const date_raw = "2003-12-13T18:30:02Z";

        const year = try fmt.parseUnsigned(u32, raw[0..4], 10);
        const month = try fmt.parseUnsigned(u32, raw[5..7], 10);
        const day = try fmt.parseUnsigned(u32, raw[8..10], 10);

        assert(date_raw[10] == 'T');

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
    l.warn("\n", .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const contents = @embedFile("../test/atom.xml");
    const result = try Atom.parse(allocator, contents);
    testing.expectEqualStrings("Example Feed", result.title);
    testing.expectEqualStrings("urn:uuid:60a76c80-d399-11d9-b93C-0003939e0af6", result.id.?);
    testing.expectEqualStrings("http://example.org/feed/", result.link.?);
    testing.expectEqualStrings("2012-12-13T18:30:02Z", result.updated_raw.?);

    expect(2 == result.items.len);
    // TODO: test feed items
    // l.warn("items.len: {}", .{result.items.len});
}

test "Atom.parseDateToUtc" {
    l.warn("\n", .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    {
        const date_raw = "2003-12-13T18:30:02Z";
        const dt = try Atom.parseDateToUtc(date_raw);
        expect(2003 == dt.date.year);
        expect(12 == dt.date.month);
        expect(13 == dt.date.day);
        expect(18 == dt.time.hour);
        expect(30 == dt.time.minute);
        expect(02 == dt.time.second);
        expect(0 == dt.time.nanosecond);
        expect(0 == dt.zone.offset);
    }
    {
        const date_raw = "2003-12-13T18:30:02.25Z";
        const dt = try Atom.parseDateToUtc(date_raw);
        expect(2003 == dt.date.year);
        expect(12 == dt.date.month);
        expect(13 == dt.date.day);
        expect(18 == dt.time.hour);
        expect(30 == dt.time.minute);
        expect(02 == dt.time.second);
        expect(250000000 == dt.time.nanosecond);
        expect(0 == dt.zone.offset);
    }
    {
        const date_raw = "2003-12-13T18:30:02+01:00";
        const dt = try Atom.parseDateToUtc(date_raw);
        expect(2003 == dt.date.year);
        expect(12 == dt.date.month);
        expect(13 == dt.date.day);
        expect(17 == dt.time.hour);
        expect(30 == dt.time.minute);
        expect(02 == dt.time.second);
        expect(0 == dt.time.nanosecond);
        expect(0 == dt.zone.offset);
    }
    {
        const date_raw = "2003-12-13T18:30:02.25+01:00";
        const dt = try Atom.parseDateToUtc(date_raw);
        expect(2003 == dt.date.year);
        expect(12 == dt.date.month);
        expect(13 == dt.date.day);
        expect(17 == dt.time.hour);
        expect(30 == dt.time.minute);
        expect(02 == dt.time.second);
        expect(250000000 == dt.time.nanosecond);
        expect(0 == dt.zone.offset);
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

    pub fn parse(allocator: *Allocator, contents: []const u8) !Feed {
        var items = try ArrayList(Feed.Item).initCapacity(allocator, 10);
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
                            } else if (mem.eql(u8, "item", tag)) {
                                state = .item;
                                item_title = null;
                                item_description = null;
                                item_guid = null;
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
                        const title = blk: {
                            if (item_title) |value| {
                                break :blk value;
                            } else if (item_description) |value| {
                                const max_len: usize = 30;
                                const len = if (value.len > max_len) max_len else value.len;
                                break :blk value[0..len];
                            }
                            return error.InvalidRssFeed;
                        };

                        // TODO: handle and parse date
                        // const date_utc = item_pub_date;
                        const item = Feed.Item{
                            .title = title,
                            .id = item_guid,
                            .link = item_link,
                            .updated_raw = item_pub_date,
                        };
                        try items.append(item);

                        state = .channel;
                    }
                },
                .attribute => |attr| {
                    // warn("attribute\n", .{});
                    // warn("\tname: {s}\n", .{attr.name});
                    // warn("\traw_value: {s}\n", .{attr.raw_value});
                },
                .comment => |str| {
                    // warn("comment: {s}\n", .{str});
                },
                .processing_instruction => |str| {
                    // warn("processing_instruction: {s}\n", .{str});
                },
                .character_data => |value| {
                    // warn("character_data: {s}\n", .{value});

                    // TODO: string handling for description (and others where needed).
                    // [ ] might only get partial string
                    // [ ] whole text or part of text might be wrapped in CDATA
                    // [ ] string might contain html(xml) elements
                    // https://www.rssboard.org/rss-encoding-examples
                    switch (state) {
                        .channel => {
                            switch (channel_field) {
                                .title => {
                                    feed_title = value;
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
                                ._ignore => {},
                            }
                        },
                        .item => {
                            switch (item_field) {
                                .title => {
                                    item_title = value;
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
                                    item_description = value;
                                },
                                ._ignore => {},
                            }
                        },
                    }
                },
            }
        }

        const date_raw = feed_pub_date orelse feed_build_date;
        // TODO: parse date
        // const date_utc = date_raw;
        const result = Feed{
            .title = feed_title orelse return error.InvalidRssFeed,
            .id = null,
            .link = feed_link,
            .updated_raw = date_raw,
            .items = items.toOwnedSlice(),
        };

        return result;
    }
};

test "rss" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const contents = @embedFile("../test/sample-rss-2.xml");
    var feed = try Rss.parse(allocator, contents);
    std.testing.expectEqualStrings("Liftoff News", feed.title);
    std.testing.expectEqualStrings("http://liftoff.msfc.nasa.gov/", feed.link.?);
    std.testing.expectEqualStrings("Tue, 10 Jun 2003 04:00:00 +0100", feed.updated_raw.?);
    expect(6 == feed.items.len);
    // Description is used as title
    // std.testing.expectEqualStrings("Sky watchers in Europe, Asia, ", feed.items[1].title);
}

pub fn rssStringToTimezone(str: []const u8) *const datetime.Timezone {
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

pub fn pubDateToDateTime(str: []const u8) !Datetime {
    var iter = mem.split(str, " ");

    // Skip: don't care about day of week
    _ = iter.next();

    // Day of month
    const day_str = iter.next() orelse return error.InvalidPubDate;
    const day = try fmt.parseInt(u8, day_str, 10);

    // month
    const month_str = iter.next() orelse return error.InvalidPubDate;
    const month = @enumToInt(try datetime.Month.parseAbbr(month_str));

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
    var time_iter = mem.split(time_str, ":");
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
        result.zone = rssStringToTimezone(tz_str);
    }

    return result;
}

pub fn pubDateToTimestamp(str: []const u8) !i64 {
    const datetime_raw = try pubDateToDateTime(str);
    const date_time_utc = datetime_raw.shiftTimezone(&timezones.UTC);
    return @intCast(i64, date_time_utc.toTimestamp());
}

test "rss time to sqlite time" {
    {
        const date_str = "Tue, 03 Jun 2003 09:39:21 GMT";
        const date = try pubDateToDateTime(date_str);
        expect(2003 == date.date.year);
        expect(6 == date.date.month);
        expect(3 == date.date.day);
        expect(9 == date.time.hour);
        expect(39 == date.time.minute);
        expect(21 == date.time.second);
        expect(date.zone.offset == 0);
    }

    {
        // dates with timezone format +/-NNNN will be turned into UTC
        const date_str = "Wed, 01 Oct 2002 01:00:00 +0200";
        const date = try pubDateToDateTime(date_str);
        expect(2002 == date.date.year);
        expect(9 == date.date.month);
        expect(30 == date.date.day);
        expect(23 == date.time.hour);
        expect(0 == date.time.minute);
        expect(0 == date.time.second);
        expect(date.zone.offset == 0);
    }

    {
        // dates with timezone format +/-NNNN will be turned into UTC
        const date_str = "Wed, 01 Oct 2002 01:00:00 -0200";
        const date = try pubDateToDateTime(date_str);
        expect(2002 == date.date.year);
        expect(10 == date.date.month);
        expect(1 == date.date.day);
        expect(3 == date.time.hour);
        expect(0 == date.time.minute);
        expect(0 == date.time.second);
        expect(date.zone.offset == 0);
    }
}
