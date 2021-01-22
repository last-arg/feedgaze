const std = @import("std");
const xml = @import("xml");
const warn = std.debug.warn;
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const l = std.log;
const datetime = @import("datetime");
const Datetime = datetime.Datetime;
const timezones = datetime.timezones;

// TODO: add sample-all.rss file with all fields present
// TODO: quite alot of feeds use these fields
// <sy:updatePeriod>hourly</sy:updatePeriod>
// <sy:updateFrequency>1</sy:updateFrequency>
// has something to do with attributes in xml element
// xmlns:sy="http://purl.org/rss/1.0/modules/syndication/"

pub const Feed = struct {
    const Self = @This();
    allocator: *Allocator,
    info: Info,
    items: []Item,

    // TODO?: rss spec also requires description field. do I need it?
    const Info = struct {
        title: []const u8,
        link: []const u8,
        location: []const u8, // Used by sqlite as unique id
        pub_date: ?[]const u8 = null,
        pub_date_utc: ?i64 = null,
        image_url: ?[]const u8 = null,
        last_build_date: ?[]const u8 = null, // last time rss file was generated
        last_build_date_utc: ?i64 = null, // last time rss file was generated
        ttl: ?u32 = null, // in minutes until cache refresh
    };

    // location and contents memory isn't owned by Feed struct.
    // Feed struct fields are valid as long as location and contents aren't freed.
    pub fn init(allocator: *Allocator, location: []const u8, contents: []const u8) !Self {
        var feed = Self{
            .allocator = allocator,
            .info = undefined,
            .items = undefined,
        };
        try feed.parse(location, contents);
        try feed.datesToTimestamp();
        return feed;
    }

    pub fn datesToTimestamp(feed: *Self) !void {
        if (feed.info.pub_date) |str| {
            feed.info.pub_date_utc = try pubDateToTimestamp(str);
        }

        if (feed.info.last_build_date) |str| {
            feed.info.last_build_date_utc = try pubDateToTimestamp(str);
        }

        for (feed.items) |*it| {
            if (it.pub_date) |str| {
                it.pub_date_utc = try pubDateToTimestamp(str);
            }
        }
    }

    pub fn parse(feed: *Self, location: []const u8, contents: []const u8) !void {
        const allocator = feed.allocator;
        var items = try ArrayList(Item).initCapacity(allocator, 10);
        errdefer items.deinit();

        var state: State = .channel;
        var channel_field: ChannelField = ._ignore;
        var item_field: ItemField = ._ignore;

        var item: *Item = undefined;
        var item_title: ?[]const u8 = null;
        var item_description: ?[]const u8 = null;

        var info = Info{
            .title = undefined,
            .link = undefined,
            .location = location,
        };
        var info_title: ?[]const u8 = null;
        var info_link: ?[]const u8 = null;

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
                            } else if (mem.eql(u8, "last_build_date", tag)) {
                                channel_field = .last_build_date;
                            } else if (mem.eql(u8, "ttl", tag)) {
                                channel_field = .ttl;
                            } else if (mem.eql(u8, "item", tag)) {
                                state = .item;
                                item = try items.addOne();
                                item.link = null;
                                item.pub_date = null;
                                item.pub_date_utc = null;
                                item.guid = null;
                            } else if (mem.eql(u8, "image", tag)) {
                                channel_field = .image;
                            } else if (channel_field == .image) {
                                if (mem.eql(u8, "url", tag)) {
                                    channel_field = .image_url;
                                }
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
                        state = .channel;
                        if (item_title) |value| {
                            item.*.title = value;
                        } else if (item_description) |value| {
                            const max_len: usize = 30;
                            const len = if (value.len > max_len) max_len else value.len;
                            item.*.title = value[0..len];
                        } else {
                            // Reset old data incase addOne() keeps old data
                            item.*.link = null;
                            item.*.pub_date = null;
                            item.*.pub_date_utc = null;
                            item.*.guid = null;
                            _ = items.pop();
                        }

                        item_title = null;
                        item_description = null;
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
                    if (str.len < 3 or !mem.eql(u8, "xml", str[0..3])) {
                        return error.InvalidXml;
                    }
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
                                    info_title = value;
                                },
                                .link => {
                                    info_link = value;
                                },
                                .pub_date => {
                                    info.pub_date = value;
                                },
                                .image_url => {
                                    info.image_url = value;
                                },
                                .last_build_date => {
                                    info.last_build_date = value;
                                },
                                .ttl => {
                                    l.warn("value: {s}", .{value});
                                    info.ttl = try std.fmt.parseInt(u32, value, 10);
                                },
                                ._ignore, .image => {},
                            }
                        },
                        .item => {
                            switch (item_field) {
                                .title => {
                                    item_title = value;
                                },
                                .link => {
                                    item.*.link = value;
                                },
                                .pub_date => {
                                    item.*.pub_date = value;
                                },
                                .guid => {
                                    item.*.guid = value;
                                },
                                .description => {
                                    item_description = item_description orelse value;
                                },
                                ._ignore => {},
                            }
                        },
                    }
                },
            }
        }

        if (info_link == null) return error.RssMissingTitle;
        if (info_title == null) return error.RssMissingLink;
        info.link = info_link.?;
        info.title = info_title.?;
        feed.info = info;
        feed.items = items.toOwnedSlice();
    }

    pub fn deinit(feed: @This()) void {
        feed.allocator.free(feed.items);
    }
};

// All of Item's fields are optional-ish. At least title or description has to present.
// TODO?: add source field. points to rss channel where the item came from.
// Would have to search item based on title or description (partial?).
// Source field would be used only if there is no link field.
pub const Item = struct {
    title: []const u8,
    link: ?[]const u8 = null,
    pub_date: ?[]const u8 = null,
    pub_date_utc: ?i64 = null,
    guid: ?[]const u8 = null,
};

const State = union(enum) {
    channel,
    item,
};

const ChannelField = enum {
    title,
    link,
    pub_date,
    last_build_date,
    ttl,
    image,
    image_url,
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

test "rss" {
    var allocator = std.testing.allocator;
    const location = "test/sample-rss-2.xml";
    var file = try std.fs.cwd().openFile(location, .{});
    var file_stat = try file.stat();
    const contents = try file.reader().readAllAlloc(allocator, file_stat.size);
    defer allocator.free(contents);
    var feed = try Feed.init(allocator, location, contents);
    std.testing.expectEqualStrings("Liftoff News", feed.info.title);
    // Description is used as title
    std.testing.expectEqualStrings("Sky watchers in Europe, Asia, ", feed.items[1].title);
    defer feed.deinit();
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
    const expect = testing.expect;
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
