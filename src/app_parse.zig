const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const print = std.debug.print;

const max_title_len = 512;
const default_item_count = @import("./app_config.zig").max_items;

pub const FeedAndItems = struct {
    feed: Feed,
    items: []FeedItem,
};

const TmpStr = std.BoundedArray(u8, max_title_len);

fn constructTmpStr(tmp_str: *TmpStr, data: []const u8) void {
    if (tmp_str.capacity() == tmp_str.len) {
        return;
    }
    const end = blk: {
        const new_len = tmp_str.len + data.len;
        if (new_len > tmp_str.capacity()) {
            break :blk tmp_str.capacity() - tmp_str.len;
        }
        break :blk data.len;
    };
    if (end > 0) {
        tmp_str.appendSliceAssumeCapacity(data[0..end]);
    }
}

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
    id,

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
    var tmp_str = TmpStr.init(0) catch unreachable;
    var tmp_entries = std.BoundedArray(FeedItem, 10).init(0) catch unreachable;
    var entries = try std.ArrayList(FeedItem).initCapacity(allocator, default_item_count);
    defer entries.deinit();
    var feed = Feed{ .feed_url = "" };
    var state: AtomParseState = .feed;
    var current_tag: ?AtomParseTag = null;
    var current_entry: ?*FeedItem = null;
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
                    if (state == .entry) {
                        current_entry = tmp_entries.addOne() catch blk: {
                            try entries.appendSlice(tmp_entries.slice());
                            tmp_entries.resize(0) catch unreachable;
                            break :blk tmp_entries.addOne() catch unreachable;
                        };
                        current_entry.?.* = .{ .title = undefined };
                    }
                }
            },
            .element_content => {
                if (current_tag == null) {
                    continue;
                }
                const elem_content = token_reader.fullToken(token).element_content.content;
                switch (state) {
                    .feed => switch (current_tag.?) {
                        .title => switch (elem_content) {
                            .text => |text| try tmp_str.appendSlice(text),
                            .codepoint => |cp| {
                                var buf: [3]u8 = undefined;
                                const len = try std.unicode.utf8Encode(cp, &buf);
                                try tmp_str.appendSlice(buf[0..len]);
                            },
                            .entity => |ent| {
                                try tmp_str.append('&');
                                try tmp_str.appendSlice(ent);
                                try tmp_str.append(';');
                            },
                        },
                        // <link /> is void element
                        .link => {},
                        // Can be site url. Don't need it because already
                        // have fallback url from fn arg 'url'.
                        .id => {},
                        .updated => feed.updated_raw = try allocator.dupe(u8, elem_content.text),
                    },
                    .entry => switch (current_tag.?) {
                        .title => switch (elem_content) {
                            .text => |text| try tmp_str.appendSlice(text),
                            .codepoint => |cp| {
                                var buf: [3]u8 = undefined;
                                const len = try std.unicode.utf8Encode(cp, &buf);
                                try tmp_str.appendSlice(buf[0..len]);
                            },
                            .entity => |ent| {
                                try tmp_str.append('&');
                                try tmp_str.appendSlice(ent);
                                try tmp_str.append(';');
                            },
                        },
                        // <link /> is void element
                        .link => {},
                        .id => current_entry.?.id = try allocator.dupe(u8, elem_content.text),
                        .updated => current_entry.?.updated_raw = try allocator.dupe(u8, elem_content.text),
                    },
                }
            },
            .element_end => {
                if (current_tag == null) {
                    continue;
                }
                const tag = token_reader.fullToken(token).element_end.name;

                switch (state) {
                    .feed => switch (current_tag.?) {
                        .title => {
                            feed.title = try allocator.dupe(u8, tmp_str.slice());
                            tmp_str.resize(0) catch unreachable;
                        },
                        .id, .updated, .link => {},
                    },
                    .entry => {
                        switch (current_tag.?) {
                            .title => {
                                current_entry.?.title = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.resize(0) catch unreachable;
                            },
                            .id, .updated, .link => {},
                        }
                        if (mem.eql(u8, "entry", tag)) {
                            current_entry = null;
                        }
                    },
                }
                current_tag = null;
                attr_key = null;
            },
            .element_end_empty => {
                if (current_tag == null) {
                    continue;
                }

                switch (state) {
                    .feed => switch (current_tag.?) {
                        .link => {
                            if (link_href) |href| {
                                if (mem.eql(u8, "alternate", link_rel)) {
                                    feed.page_url = href;
                                } else if (mem.eql(u8, "self", link_rel)) {
                                    feed.feed_url = href;
                                }
                            }
                            link_href = null;
                            link_rel = "alternate";
                        },
                        .title, .id, .updated => {},
                    },
                    .entry => {
                        switch (current_tag.?) {
                            .link => {
                                if (link_href) |href| {
                                    if (mem.eql(u8, "alternate", link_rel)) {
                                        current_entry.?.link = href;
                                    }
                                }
                                link_href = null;
                                link_rel = "alternate";
                            },
                            .title, .id, .updated => {},
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
                    .title, .id, .updated => {},
                }

            },
            .xml_declaration,
            .pi_start, .pi_content,
            .comment_start, .comment_content => {},
        }
    }
    if (tmp_entries.len > 0) {
        try entries.appendSlice(tmp_entries.slice());
    }

    return .{
        .feed = feed,
        .items = try entries.toOwnedSlice(),
    };
}

test "parseAtom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = @embedFile("atom.atom");
    const result = try parse(arena.allocator(), content, .atom);
    const expect_feed = Feed{
        .title = "Example Feed",
        .feed_url = "http://example.org/feed/",
        .page_url = "http://example.org/",
        .updated_raw = "2012-12-13T18:30:02Z",
    };
    try std.testing.expectEqualDeep(expect_feed, result.feed);
    var expect_items = [_]FeedItem{ .{
        .title = "Atom-Powered Robots Run Amok",
        .link = "http://example.org/2003/12/13/atom03",
        .id = "urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a",
        .updated_raw = "2008-11-13T18:30:02Z",
    }, .{
        .title = "Entry one's 1",
        .link = "http://example.org/2008/12/13/entry-1",
        .id = "urn:uuid:2225c695-dfb8-5ebb-baaa-90da344efa6a",
        .updated_raw = "2005-12-13T18:30:02Z",
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
    guid,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

pub fn parseRss(allocator: Allocator, content: []const u8) !FeedAndItems {
    var tmp_str = TmpStr.init(0) catch unreachable;
    var tmp_entries = std.BoundedArray(FeedItem, 10).init(0) catch unreachable;
    var entries = try std.ArrayList(FeedItem).initCapacity(allocator, default_item_count);
    defer entries.deinit();
    var feed = Feed{ .feed_url = "" };
    var state: RssParseState = .channel;
    var current_tag: ?RssParseTag = null;
    var current_item: ?*FeedItem = null;

    var stream = std.io.fixedBufferStream(content);
    var input_buffered_reader = std.io.bufferedReader(stream.reader());
    var token_reader = zig_xml.tokenReader(input_buffered_reader.reader(), .{});

    var token = try token_reader.next();
    while (token != .eof) : (token = try token_reader.next()) {
        switch (token) {
            .eof => break,
            .element_start => {
                const tag = token_reader.fullToken(token).element_start.name;
                current_tag = RssParseTag.fromString(tag);
                if (RssParseState.fromString(tag)) |new_state| {
                    state = new_state;
                    if (state == .item) {
                        current_item = tmp_entries.addOne() catch blk: {
                            try entries.appendSlice(tmp_entries.slice());
                            tmp_entries.resize(0) catch unreachable;
                            break :blk tmp_entries.addOne() catch unreachable;
                        };
                        current_item.?.* = .{ .title = "" };
                    }
                }
            },
            .element_content => {
                if (current_tag == null) {
                    continue;
                }
                const elem_content = token_reader.fullToken(token).element_content.content;

                switch (state) {
                    .channel => switch (current_tag.?) {
                        .title => switch (elem_content) {
                            .text => |text| try tmp_str.appendSlice(text),
                            .codepoint => |cp| {
                                var buf: [3]u8 = undefined;
                                const len = try std.unicode.utf8Encode(cp, &buf);
                                try tmp_str.appendSlice(buf[0..len]);
                            },
                            .entity => |ent| {
                                try tmp_str.append('&');
                                try tmp_str.appendSlice(ent);
                                try tmp_str.append(';');
                            },
                        },
                        .link => feed.page_url = try allocator.dupe(u8, elem_content.text),
                        .pubDate => feed.updated_raw = try allocator.dupe(u8, elem_content.text),
                        .guid, .description => {},
                    },
                    .item => switch (current_tag.?) {
                        .title => switch (elem_content) {
                            .text => |text| try tmp_str.appendSlice(text),
                            .codepoint => |cp| {
                                var buf: [4]u8 = undefined;
                                const len = try std.unicode.utf8Encode(cp, &buf);
                                try tmp_str.appendSlice(buf[0..len]);
                            },
                            .entity => |ent| {
                                try tmp_str.append('&');
                                try tmp_str.appendSlice(ent);
                                try tmp_str.append(';');
                            },
                        },
                        .description => if (current_item.?.title.len == 0) {
                            switch (elem_content) {
                                .text => |text| try tmp_str.appendSlice(text),
                                .codepoint => |cp| {
                                    var buf: [3]u8 = undefined;
                                    const len = try std.unicode.utf8Encode(cp, &buf);
                                    try tmp_str.appendSlice(buf[0..len]);
                                },
                                .entity => |ent| {
                                    try tmp_str.append('&');
                                    try tmp_str.appendSlice(ent);
                                    try tmp_str.append(';');
                                },
                            }
                        },
                        .link, .guid => switch (elem_content) {
                            .text => |text| try tmp_str.appendSlice(text),
                            .codepoint => |cp| {
                                var buf: [3]u8 = undefined;
                                const len = try std.unicode.utf8Encode(cp, &buf);
                                try tmp_str.appendSlice(buf[0..len]);
                            },
                            .entity => |ent| {
                                try tmp_str.append('&');
                                try tmp_str.appendSlice(ent);
                                try tmp_str.append(';');
                            },
                        },
                        .pubDate => current_item.?.updated_raw = try allocator.dupe(u8, elem_content.text),
                    },
                }
            },
            .element_end => {
                const tag = token_reader.fullToken(token).element_end.name;
                if (RssParseState.fromString(tag)) |end_tag| {
                    if (end_tag == .item) {
                        state = .channel;
                    }
                }

                if (current_tag == null) {
                    continue;
                }

                switch (state) {
                    .channel => switch (current_tag.?) {
                        .title => {
                            feed.title = try allocator.dupe(u8, tmp_str.slice());
                            tmp_str.resize(0) catch unreachable;
                        },
                        .link, .guid, .pubDate, .description => {},
                    },
                    .item => {
                        switch (current_tag.?) {
                            .title => {
                                current_item.?.title = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.resize(0) catch unreachable;
                            },
                            .description => {
                                if (current_item.?.title.len == 0) {
                                    current_item.?.title = try allocator.dupe(u8, tmp_str.slice());
                                    tmp_str.resize(0) catch unreachable;
                                }
                            },
                            .link => {
                                current_item.?.link = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.resize(0) catch unreachable;
                            }, 
                            .guid => {
                                current_item.?.id = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.resize(0) catch unreachable;
                            }, 
                            .pubDate => {},
                        }
                    },
                }
                current_tag = null;
            },
            .element_end_empty => {
                current_tag = null;
            },
            .attribute_start => {},
            .attribute_content => {},
            .xml_declaration,
            .pi_start, .pi_content,
            .comment_start, .comment_content => {},
        }
    }

    if (tmp_entries.len > 0) {
        try entries.appendSlice(tmp_entries.slice());
    }

    return .{
        .feed = feed,
        .items = try entries.toOwnedSlice(),
    };
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
        .updated_raw = "Tue, 10 Jun 2003 04:00:00 +0100",
    };

    try std.testing.expectEqualDeep(expect_feed, result.feed);
    const expect_items = [_]FeedItem{ .{
        .title = "Star City's Test",
        .link = "http://liftoff.msfc.nasa.gov/news/2003/news-starcity.asp",
        .updated_raw = "Tue, 03 Jun 2003 09:39:21 GMT",
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

    const html =
        \\<!DOCTYPE html>
    ;
    const html_type = getContentType(html);
    try std.testing.expectEqual(ContentType.html, html_type.?);
}

pub fn parse(allocator: Allocator, content: []const u8, content_type: ?ContentType) !FeedAndItems {
    _ = content_type;

    // Figure out content type based on file content
    // Server might return wrong content type. Like 'https://jakearchibald.com/'
    // TODO?: Could run parse with provided content type and then if there
    // is no feed.items (or some other condition) check content type based on
    // file content. If new content type is different from initial content
    // type re-run parse.
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
