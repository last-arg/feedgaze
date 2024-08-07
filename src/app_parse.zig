const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const feed_types = @import("./feed_types.zig");
const RssDateTime = feed_types.RssDateTime;
const AtomDateTime = feed_types.AtomDateTime;
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const print = std.debug.print;

const max_title_len = 512;
const default_item_count = @import("./app_config.zig").max_items;

pub const FeedAndItems = struct {
    feed: Feed,
    items: []FeedItem,

    pub fn feed_updated_timestamp(self: *FeedAndItems, fallback_timestamp: ?i64) void {
        if (self.items.len > 0 and self.items[0].updated_timestamp != null) {
            // make feed date newest item date
            self.feed.updated_timestamp = self.items[0].updated_timestamp;
        } else if (fallback_timestamp != null) {
            self.feed.updated_timestamp = fallback_timestamp;
        } else {
            self.feed.updated_timestamp = std.time.timestamp();
        }
    }

    pub fn prepareAndValidate(self: *FeedAndItems, alloc: std.mem.Allocator, fallback_timestamp: ?i64) !void {
        try self.feed.prepareAndValidate(alloc);
        if (self.items.len > 0) {
            self.feed_updated_timestamp(fallback_timestamp);

            const item_first = self.items[0];
            // Set all items ids
            if (item_first.feed_id == 0 and self.feed.feed_id != 0) { 
                for (self.items) |*item| {
                    item.*.feed_id = self.feed.feed_id;
                }
            }

            // Set item dates to now if missing
            // Set null values to current time until non-null value
            if (item_first.updated_timestamp == null) {
                const now = @divFloor(std.time.milliTimestamp(), 1000);
                for (self.items) |*item| {
                    if (item.updated_timestamp == null) {
                        item.*.updated_timestamp = now;
                    } else {
                        break;
                    }
                }
            }

            const feed_uri = try std.Uri.parse(self.feed.feed_url);
            for (self.items) |*item| {
                if (item.link) |*link| if (link.len > 0 and link.*[0] == '/') {
                    link.* = try std.fmt.allocPrint(alloc, "{;+}{s}", .{feed_uri, link.*});
                };
            }
        }
    }
};

pub const TmpStr = struct {
    const Self = @This();
    const Str = std.BoundedArray(u8, max_title_len);
    const ContentState = enum { text, skip, lt };

    arr: Str,
    is_full: bool = false,
    state: ContentState = .text,
    is_prev_amp: bool = false,

    fn init() Self {
        return .{ .arr = Str.init(0) catch unreachable };
    }

    const html = @import("./html.zig");
    pub fn content_to_str(tmp_str: *TmpStr, elem_content: zig_xml.Token.Content) !void {
        if (tmp_str.is_full) {
            return;
        }

        const state = tmp_str.state;
        switch (elem_content) {
            .text => |text| {
                if (state == .lt) {
                    if (mem.eql(u8, text, "p") or mem.eql(u8, text, "/p")) {
                        const len = tmp_str.arr.len;
                        if (len > 0 and tmp_str.arr.buffer[len - 1] != ' ') {
                            tmp_str.append(' ');
                        }
                    }
                        
                    if (text.len > 0 and (std.ascii.isAlphabetic(text[0]) or text[0] == '/')) {
                        tmp_str.state = .skip;
                    }
                    return;
                } else if (state == .skip) {
                    return;
                }

                var t = text;
                if (tmp_str.is_prev_amp) {
                    if (mem.indexOfScalar(u8, text, ';')) |index| {
                        tmp_str.entity_to_str(text[0..index]);
                        const start = index + 1;
                        if (start >= t.len) {
                            return;
                        }
                        t = text[index + 1..];
                    }
                    tmp_str.is_prev_amp = false;
                }

                var iter = html.html_text(t);
                while (iter.next()) |value| {
                    tmp_str.appendSlice(value);
                }
            },
            .codepoint => |cp| {
                if (state == .text) {
                    if (tmp_str.is_prev_amp) {
                        tmp_str.append('&');
                        tmp_str.is_prev_amp = false;
                    }

                    var buf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(cp, &buf);
                    tmp_str.appendSlice(buf[0..len]);
                }
            },
            .entity => |ent| entity_to_str(tmp_str, ent),
        }
    }

    fn entity_to_str(tmp_str: *TmpStr, ent: []const u8) void {
        if (mem.eql(u8, ent, "lt")) {
            tmp_str.state = .lt;
        } else if (mem.eql(u8, ent, "gt")) {
            tmp_str.state = .text;
        } else if (tmp_str.state != .skip) {
            if (entity_to_char(ent)) |char| {
                if (char == '&' and !tmp_str.is_prev_amp) {
                    tmp_str.is_prev_amp = true;
                } else {
                    tmp_str.append(char);
                }
            } else {
                tmp_str.append('&');
                tmp_str.appendSlice(ent);
                tmp_str.append(';');
            }
        }
    }

    fn entity_to_char(entity: []const u8) ?u8 {
        if (mem.eql(u8, entity, "amp")) {
            return '&';
        } else if (mem.eql(u8, entity, "quot")) {
            return '\"';
        }
        return null;
    }

    fn append(self: *Self, item: u8) void {
        if (self.is_full) {
            return;
        }
        self.arr.append(item) catch {
            self.is_full = true;
        };
    }

    // TODO?: add space when block (<p>) element?
    fn appendSlice(self: *Self, items: []const u8) void {
        if (self.is_full) {
            return;
        }
        const trim_left = mem.trimLeft(u8, items, &std.ascii.whitespace);
        if (self.arr.len > 0 and self.arr.buffer[self.arr.len - 1] != ' ' and trim_left.len < items.len) {
            self.append(' ');
        }
        if (trim_left.len == 0) {
            return;
        }

        const trimmed = mem.trimRight(u8, trim_left, &std.ascii.whitespace);

        const space_left = self.arr.capacity() - self.arr.len;
        const tmp_items = trimmed[0..@min(trimmed.len, space_left)];
        self.arr.appendSlice(tmp_items) catch {
            self.is_full = true;
        };

        if (trimmed.len < trim_left.len) {
            self.append(' ');
        }
    }
    
    fn reset(self: *Self) void {
        self.is_full = false;
        self.arr.resize(0) catch unreachable;
        self.state = .text;
    }

    fn slice(self: *Self) []const u8 {
        return mem.trimRight(u8, self.arr.slice(), &std.ascii.whitespace);
    }
};

const AtomParseState = enum {
    feed,
    entry,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        var iter = std.mem.splitAny(u8, str, &std.ascii.whitespace);
        if (iter.next()) |value| {
            return std.meta.stringToEnum(Self, value);
        }
        return null;
    }
};

const AtomParseTag = enum {
    title,
    link,
    updated,
    published,
    id,
    icon,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

const AtomLinkAttr = enum {
    href,
    rel, 
};

pub fn parseAtom(allocator: Allocator, content: []const u8) !FeedAndItems {
    var tmp_str = TmpStr.init();
    var entries = try std.ArrayList(FeedItem).initCapacity(allocator, default_item_count);
    defer entries.deinit();
    var feed = Feed{ .feed_url = "" };
    var state: AtomParseState = .feed;
    var current_tag: ?AtomParseTag = null;
    var current_entry: FeedItem = .{ .title = "" };
    var link_href: ?[]const u8 = null;
    var link_rel: []const u8 = "alternate";
    var attr_key: ?AtomLinkAttr = null;

    var stream = std.io.fixedBufferStream(content);
    var input_buffered_reader = std.io.bufferedReader(stream.reader());
    var token_reader = zig_xml.tokenReader(input_buffered_reader.reader(), .{});

    var token = try token_reader.next();
    while (token != .eof) : (token = try token_reader.next()) {
        switch (token) {
            .eof => break,
            .element_start => {
                const tag = token_reader.fullToken(token).element_start.name;
                current_tag = AtomParseTag.fromString(tag);
                if (AtomParseState.fromString(tag)) |new_state| {
                    state = new_state;
                }
            },
            .element_content => {
                const tag = current_tag orelse continue;
                const elem_content = token_reader.fullToken(token).element_content.content;
                switch (state) {
                    .feed => switch (tag) {
                        .title => try tmp_str.content_to_str(elem_content),
                        // <link /> is void element
                        .link => {},
                        // Can be site url. Don't need it because already
                        // have fallback url from fn arg 'url'.
                        .id => {},
                        .updated => feed.updated_timestamp = AtomDateTime.parse(elem_content.text) catch null,
                        .published => {},
                        .icon => {
                            if (feed.icon_url == null) {
                                feed.icon_url = try allocator.dupe(u8, mem.trim(u8, elem_content.text, &std.ascii.whitespace));
                            }
                        }
                    },
                    .entry => switch (tag) {
                        .title => try tmp_str.content_to_str(elem_content),
                        // <link /> is void element
                        .link => {},
                        .id => current_entry.id = try allocator.dupe(u8, elem_content.text),
                        .updated => {
                            if (current_entry.updated_timestamp == null) {
                                if (AtomDateTime.parse(elem_content.text) catch null) |ts| {
                                    current_entry.updated_timestamp = ts;
                                }
                            }
                        },
                        .published => {
                            if (AtomDateTime.parse(elem_content.text) catch null) |ts| {
                                current_entry.updated_timestamp = ts;
                            }
                        },
                        .icon => {}
                    },
                }
            },
            .element_end => {
                const tag_str = token_reader.fullToken(token).element_end.name;
                if (mem.eql(u8, "entry", tag_str)) {
                    add_or_replace_item(&entries, current_entry);
                    current_entry = .{ .title = "" };
                    state = .feed;
                    continue;
                }
                const tag = current_tag orelse continue;
                switch (state) {
                    .feed => switch (tag) {
                        .title => {
                            feed.title = try allocator.dupe(u8, tmp_str.slice());
                            tmp_str.reset();
                        },
                        .id, .updated, .link, .published, .icon => {},
                    },
                    .entry => {
                        switch (tag) {
                            .title => {
                                current_entry.title = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.reset();
                            },
                            .id, .updated, .link, .published, .icon => {},
                        }
                    },
                }
                current_tag = null;
                attr_key = null;
            },
            .element_end_empty => {
                const tag = current_tag orelse continue;

                switch (state) {
                    .feed => switch (tag) {
                        .link => {
                            if (link_href) |href| {
                                if (mem.eql(u8, "alternate", link_rel)) {
                                    feed.page_url = href;
                                }
                            }
                            link_href = null;
                            link_rel = "alternate";
                        },
                        .title, .id, .updated, .published, .icon => {},
                    },
                    .entry => {
                        switch (tag) {
                            .link => {
                                if (link_href) |href| {
                                    if (mem.eql(u8, "alternate", link_rel)) {
                                        current_entry.link = href;
                                    }
                                }
                                link_href = null;
                                link_rel = "alternate";
                            },
                            .title, .id, .updated, .published, .icon => {},
                        }
                    },
                }
                current_tag = null;
                attr_key = null;
            },
            .attribute_start => {
                if (current_tag == null) {
                    continue;
                }

                const key = token_reader.fullToken(token).attribute_start.name;
                if (mem.eql(u8, "href", key)) {
                    attr_key = .href;
                } else if (mem.eql(u8, "rel", key)) {
                    attr_key = .rel;
                } else {
                    attr_key = null;
                }
            },
            .attribute_content => {
                if (current_tag == null or attr_key == null) {
                    continue;
                }

                switch (current_tag.?) {
                    .link => {
                        const attr_content = token_reader.fullToken(token).attribute_content.content;
                        if (attr_content != .text) {
                            continue;
                        }
                        const attr_value = attr_content.text;
                        switch (attr_key.?) {
                            .href => link_href = try allocator.dupe(u8, attr_value),
                            .rel => link_rel = try allocator.dupe(u8, attr_value),
                        }
                    },
                    .title, .id, .updated, .published, .icon => {},
                }

            },
            .xml_declaration,
            .pi_start, .pi_content,
            .comment_start, .comment_content => {},
        }
    }

    const items = try entries.toOwnedSlice();
    sortItems(items);

    return .{ .feed = feed, .items = items };
}

test "parseAtom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = @embedFile("atom.atom");
    const result = try parse(arena.allocator(), content, .atom);
    const expect_feed = Feed{
        .title = "Example Feed",
        .feed_url = "",
        .page_url = "http://example.org/",
        .updated_timestamp = try AtomDateTime.parse("2012-12-13T18:30:02Z"),
    };
    try std.testing.expectEqualDeep(expect_feed, result.feed);
    var expect_items = [_]FeedItem{ .{
        .title = "Atom-Powered Robots Run Amok",
        .link = "http://example.org/2003/12/13/atom03",
        .id = "urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a",
        .updated_timestamp = try AtomDateTime.parse("2008-11-13T18:30:02Z"),
    }, .{
        .title = "Entry one's 1",
        .link = "http://example.org/2008/12/13/entry-1",
        .id = "urn:uuid:2225c695-dfb8-5ebb-baaa-90da344efa6a",
        .updated_timestamp = try AtomDateTime.parse("2005-12-13T18:30:02Z"),
    } };
    // 'start' is a runtime value. Need value to be runtime to coerce array
    // into a slice.
    var start: usize = 0;
    start = 0;
    const slice = expect_items[start..expect_items.len];
    try std.testing.expectEqualDeep(slice, result.items);
}

const RssParseState = enum {
    channel,
    item,
    image,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

const RssParseTag = enum {
    title,
    description,
    link,
    pubDate,
    @"dc:date",
    guid,
    image,
    url,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

pub fn parseRss(allocator: Allocator, content: []const u8) !FeedAndItems {
    var tmp_str = TmpStr.init();
    var entries = try std.ArrayList(FeedItem).initCapacity(allocator, default_item_count);
    defer entries.deinit();
    var feed = Feed{ .feed_url = "" };
    var state: RssParseState = .channel;
    var current_tag: ?RssParseTag = null;
    var current_item: FeedItem = .{.title = ""};

    var stream = std.io.fixedBufferStream(content);
    var input_buffered_reader = std.io.bufferedReader(stream.reader());
    var token_reader = zig_xml.tokenReader(input_buffered_reader.reader(), .{});
    var is_guid_link = false;
    var guid_has_permalink = false;

    var token = try token_reader.next();
    while (token != .eof) : (token = try token_reader.next()) {
        switch (token) {
            .eof => break,
            .element_start => {
                const tag = token_reader.fullToken(token).element_start.name;
                current_tag = RssParseTag.fromString(tag);
                if (RssParseState.fromString(tag)) |new_state| {
                    state = new_state;
                }
            },
            .element_content => {
                const tag = current_tag orelse continue;
                const elem_content = token_reader.fullToken(token).element_content.content;

                switch (state) {
                    .channel => switch (tag) {
                        .title => try tmp_str.content_to_str(elem_content),
                        .link => feed.page_url = try allocator.dupe(u8, elem_content.text),
                        .pubDate => feed.updated_timestamp = RssDateTime.parse(elem_content.text) catch 
                            AtomDateTime.parse(elem_content.text) catch null,
                        .@"dc:date" => {
                            feed.updated_timestamp = AtomDateTime.parse(elem_content.text) catch null;
                        },
                        .guid, .description, .url, .image => {},
                    },
                    .image => switch (tag){
                        .url => {
                            if (feed.icon_url == null) {
                                feed.icon_url = try allocator.dupe(u8, mem.trim(u8, elem_content.text, &std.ascii.whitespace));
                            }
                        },
                        .title, .description, .link, .guid, .pubDate, .@"dc:date", .image => {}
                    },
                    .item => switch (tag) {
                        .title => try tmp_str.content_to_str(elem_content),
                        .description => if (current_item.title.len == 0) {
                            try tmp_str.content_to_str(elem_content);
                        },
                        .link, .guid => try tmp_str.content_to_str(elem_content),
                        .pubDate => {
                            if (RssDateTime.parse(elem_content.text) catch 
                                AtomDateTime.parse(elem_content.text) catch null) |ts| {
                                current_item.updated_timestamp = ts;
                            }
                        },
                        .@"dc:date" => {
                            current_item.updated_timestamp = AtomDateTime.parse(elem_content.text) catch null;
                        },
                        .url, .image => {}
                    },
                }
            },
            .element_end => {
                const tag_str = token_reader.fullToken(token).element_end.name;
                if (mem.eql(u8, "item", tag_str)) {
                    add_or_replace_item(&entries, current_item);
                    current_item = .{ .title = "" };
                    state = .channel;
                    continue;
                } else if (mem.eql(u8, "image", tag_str)) {
                    state = .channel;
                    continue;
                }

                const tag = current_tag orelse continue;

                switch (state) {
                    .channel => switch (tag) {
                        .title => {
                            feed.title = try allocator.dupe(u8, tmp_str.slice());
                            tmp_str.reset();
                        },
                        .link, .guid, .pubDate, .@"dc:date", .description, .url, .image => {},
                    },
                    .item => {
                        switch (tag) {
                            .title => {
                                current_item.title = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.reset();
                            },
                            .description => {
                                if (current_item.title.len == 0) {
                                    current_item.title = try allocator.dupe(u8, tmp_str.slice());
                                    tmp_str.reset();
                                }
                            },
                            .link => {
                                current_item.link = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.reset();
                            }, 
                            .guid => {
                                // This means that current_item.link == null and <guid> has attribute
                                // 'isPermalink'
                                if (guid_has_permalink) {
                                    current_item.link = try allocator.dupe(u8, tmp_str.slice());
                                    is_guid_link = false;
                                    guid_has_permalink = false;
                                } else {
                                    current_item.id = try allocator.dupe(u8, tmp_str.slice());
                                }
                                tmp_str.reset();
                            }, 
                            .pubDate, .@"dc:date", .url, .image => {},
                        }
                    },
                    .image => {}
                }
                current_tag = null;
            },
            .element_end_empty => {
                current_tag = null;
            },
            .attribute_start => {
                if (current_item.link == null and state == .item) {
                    const tag = current_tag orelse continue;
                    if (tag == .guid) {
                        const attr = token_reader.fullToken(token).attribute_start;
                        guid_has_permalink = std.mem.eql(u8, attr.name, "isPermaLink");
                    }
                }
            },
            .attribute_content => {
                // This means element is in <guid> and attribute is 'isPermaLink'. And
                // current_item.link == null
                if (guid_has_permalink) {
                    const attr_content = token_reader.fullToken(token).attribute_content;
                    is_guid_link = std.mem.eql(u8, attr_content.content.text, "true");
                }
            },
            .xml_declaration,
            .pi_start, .pi_content,
            .comment_start => {}, 
            .comment_content => {},
        }
    }

    const items = try entries.toOwnedSlice();
    sortItems(items);

    return .{ .feed = feed, .items = items };
}

// Sorting item.updated_timestamp
// 1) if all values are null, no sorting
// 2) if mix of nulls and values push nulls to the bottom
// TODO: instead of pushing nulls to bottom keep null where the are if mix 
// of null and values?

fn sortItems(items: []FeedItem) void {
    var has_date = false;

    for (items) |item| {
        has_date = item.updated_timestamp != null or has_date;
    }

    if (has_date) {
        const S = struct {
            pub fn less_than(_: void, lhs: FeedItem, rhs: FeedItem) bool {
                if (lhs.updated_timestamp == null) {
                    return false;
                } else if (rhs.updated_timestamp == null) {
                    return true;
                }
                return lhs.updated_timestamp.? > rhs.updated_timestamp.?;
            }
        };

        mem.sort(FeedItem, items, {}, S.less_than);
    }
}

fn add_or_replace_item(entries: *std.ArrayList(FeedItem), current_item: FeedItem) void {
    // Don't allow duplicate links. This is a contraint in sqlite DB also.
    // Maybe change this in the future? For example in 'https://gitlab.com/dejawu/ectype.atom'
    // there can be several same links. They are same links because two
    // different actions (push, delete) were taken in connection with the link.
    for (entries.items) |item| {
        if (item.link != null and current_item.link != null and
            mem.eql(u8, item.link.?, current_item.link.?)) {
            return;
        }
    }
    if (entries.items.len == default_item_count) {
        if (current_item.updated_timestamp) |current_ts| {
            var iter = std.mem.reverseIterator(entries.items);
            var oldest_ts: ?i64 = null;
            const oldest: ?FeedItem = iter.next();
            var replace_index: usize = iter.index;
            if (oldest != null and oldest.?.updated_timestamp != null) {
                oldest_ts = oldest.?.updated_timestamp.?;
                while (iter.next()) |item| {
                    if (item.updated_timestamp == null) {
                        replace_index = iter.index;
                        break;
                    } else if (item.updated_timestamp.? < oldest_ts.?) {
                        replace_index = iter.index;
                        oldest_ts = item.updated_timestamp.?;
                    }
                }
            }

            if (oldest_ts) |ts| {
                if (current_ts > ts)  {
                    entries.replaceRangeAssumeCapacity(replace_index, 1, &[_]FeedItem{current_item});
                }
            } else {
                entries.replaceRangeAssumeCapacity(replace_index, 1, &[_]FeedItem{current_item});
            }
        }
    } else {
        entries.append(current_item) catch {};
    }    
}

test "parseRss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = @embedFile("rss2.xml");
    const result = try parse(arena.allocator(), content, .rss);
    const expect_feed = Feed{
        .title = "Liftoff News",
        .feed_url = "",
        .page_url = "http://liftoff.msfc.nasa.gov/",
        .updated_timestamp = try RssDateTime.parse("Tue, 10 Jun 2003 04:00:00 +0100"),
    };

    try std.testing.expectEqualDeep(expect_feed, result.feed);
    const expect_items = [_]FeedItem{ .{
        .title = "Star City's Test",
        .link = "http://liftoff.msfc.nasa.gov/news/2003/news-starcity.asp",
        .updated_timestamp = try RssDateTime.parse("Tue, 03 Jun 2003 09:39:21 GMT"),
        .id = "http://liftoff.msfc.nasa.gov/2003/06/03.html#item573",
    }, .{
        .title = "Sky watchers in Europe, Asia, and parts of Alaska and Canada will experience a &lt;a href=\"http://science.nasa.gov/headlines/y2003/30may_solareclipse.htm\"&gt;partial eclipse of the Sun&lt;/a&gt; on Saturday, May 31st.",
    }, .{
        .title = "Third title",
        .id = "third_id",
    } };
    // 'start' is a runtime value. Need value to be runtime to coerce array
    // into a slice.
    var start: usize = 0;
    start = 0;
    try std.testing.expectEqualDeep(expect_items[start..expect_items.len], result.items);
}

pub const ContentType = feed_types.ContentType;

pub fn getContentType(content: []const u8) ?ContentType {
    var stream = std.io.fixedBufferStream(content);
    var buf_reader = std.io.bufferedReader(stream.reader());
    var r = zig_xml.tokenReader(buf_reader.reader(), .{});
    var depth: usize = 0;
    while (depth < 2) {
        const token = r.next() catch break;
        if (token == .element_start) {
            const full = r.fullToken(token);
            const tag = full.element_start.name;

            if (depth == 0) {
                if (mem.eql(u8, "feed", tag)) {
                    return .atom;
                } else if (mem.eql(u8, "rss", tag)) {
                    // pass through
                } else {
                    break;
                }
            } else if (depth == 1) {
                if (mem.eql(u8, "channel", tag)) {
                    return .rss;
                }
            }
                        
            depth += 1;
        } else if (token == .eof) {
            break;
        }
    }
    
    const trimmed = std.mem.trimLeft(u8, content, &std.ascii.whitespace);
    if (std.ascii.startsWithIgnoreCase(trimmed, "<!doctype html")) {
        return .html;
    }
    return null;
}

test "getContentType" {
    const rss =
        \\<?xml version="1.0"?>
        \\<rss version="2.0">
        \\   <channel>
        \\   </channel>
        \\</rss>
    ;
    const rss_type = getContentType(rss);
    try std.testing.expectEqual(ContentType.rss, rss_type.?);

    const atom =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\</feed>
    ;
    const atom_type = getContentType(atom);
    try std.testing.expectEqual(ContentType.atom, atom_type.?);

    const html_raw =
        \\<!DOCTYPE html>
    ;
    const html_type = getContentType(html_raw);
    try std.testing.expectEqual(ContentType.html, html_type.?);
}

pub fn parse(allocator: Allocator, content: []const u8, content_type: ?ContentType) !FeedAndItems {
    _ = content_type;

    // Figure out content type based on file content
    // Server might return wrong content type. Like 'https://jakearchibald.com/'
    const ct = getContentType(content) orelse return error.UnknownContentType;
    return switch (ct) {
        .atom => parseAtom(allocator, content),
        .rss => parseRss(allocator, content),
        .html => error.NoHtmlParse,
        .xml => error.NotAtomOrRss,
    };
}

const zig_xml = @import("xml");
fn printEvent(event: zig_xml.Event) !void {
    switch (event) {
        .xml_declaration => |xml_declaration| print("<!xml {s} {?s} {?}\n", .{ xml_declaration.version, xml_declaration.encoding, xml_declaration.standalone }),
        .element_start => |element_start| {
            print("<{?s}({?s}):{s}\n", .{ element_start.name.prefix, element_start.name.ns, element_start.name.local });
            for (element_start.attributes) |attr| {
                print("  @{?s}({?s}):{s}={s}\n", .{ attr.name.prefix, attr.name.ns, attr.name.local, attr.value });
            }
        },
        .element_content => |element_content| print("  {s}\n", .{element_content.content}),
        .element_end => |element_end| print("/{?s}({?s}):{s}\n", .{ element_end.name.prefix, element_end.name.ns, element_end.name.local }),
        .comment => |comment| print("<!--{s}\n", .{comment.content}),
        .pi => |pi| print("<?{s} {s}\n", .{ pi.target, pi.content }),
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = @embedFile("tmp_file");
    const feed = try parseRss(alloc, content);
    print("\n==========> START {d}\n", .{feed.items.len});
    print("feed.icon_url: |{?s}|\n", .{feed.feed.icon_url});
    for (feed.items) |item| {
        print("title: |{s}|\n", .{item.title});
        print("link: |{?s}|\n", .{item.link});
        print("link: |{?s}|\n", .{item.link});
        // print("date: {?d}\n", .{item.updated_timestamp});
        print("\n", .{});
    }
}
