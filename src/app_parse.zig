const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const xml = @import("zig-xml");

const max_title_len = 512;
const default_item_count = 10;

const FeedAndItems = struct {
    feed: Feed,
    items: []FeedItem,
};

const AtomParseState = enum {
    feed,
    entry,

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
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

pub fn parseAtom(allocator: Allocator, content: []const u8) !FeedAndItems {
    var tmp_str = TmpStr.init(0) catch unreachable;
    var tmp_entries = std.BoundedArray(FeedItem, 10).init(0) catch unreachable;
    var entries = try std.ArrayList(FeedItem).initCapacity(allocator, default_item_count);
    defer entries.deinit();
    var parser = xml.Parser.init(content);
    var feed = Feed{ .feed_url = "" };
    var state: AtomParseState = .feed;
    var current_tag: ?AtomParseTag = null;
    var current_entry: ?*FeedItem = null;
    var link_href: ?[]const u8 = null;
    var link_rel: []const u8 = "alternate";
    while (parser.next()) |event| {
        switch (event) {
            .open_tag => |tag| {
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
            .close_tag => |tag| {
                if (AtomParseState.fromString(tag)) |end_tag| {
                    if (end_tag == .entry) {
                        state = .feed;
                    }
                }

                if (current_tag == null) {
                    continue;
                }

                switch (state) {
                    .feed => switch (current_tag.?) {
                        .title => {
                            feed.title = try allocator.dupe(u8, tmp_str.slice());
                            tmp_str.resize(0) catch unreachable;
                        },
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
                        .id, .updated => {},
                    },
                    .entry => {
                        switch (current_tag.?) {
                            .title => {
                                current_entry.?.title = try allocator.dupe(u8, tmp_str.slice());
                                tmp_str.resize(0) catch unreachable;
                            },
                            .link => {
                                if (link_href) |href| {
                                    if (mem.eql(u8, "alternate", link_rel)) {
                                        current_entry.?.link = href;
                                    }
                                }
                                link_href = null;
                                link_rel = "alternate";
                            },
                            .id, .updated => {},
                        }
                        if (mem.eql(u8, "entry", tag)) {
                            current_entry = null;
                        }
                    },
                }
                current_tag = null;
            },
            .attribute => |attr| {
                if (current_tag == null) {
                    continue;
                }
                switch (current_tag.?) {
                    .link => {
                        if (mem.eql(u8, "href", attr.name)) {
                            link_href = attr.raw_value;
                        } else if (mem.eql(u8, "rel", attr.name)) {
                            link_rel = attr.raw_value;
                        }
                    },
                    .title, .id, .updated => {},
                }
            },
            .comment => {},
            .processing_instruction => {},
            .character_data => |data| {
                if (current_tag == null) {
                    continue;
                }
                switch (state) {
                    .feed => switch (current_tag.?) {
                        .title => constructTmpStr(&tmp_str, data),
                        // <link /> is void element
                        .link => {},
                        // Can be site url. Don't need it because already
                        // have fallback url from fn arg 'url'.
                        .id => {},
                        .updated => feed.updated_raw = data,
                    },
                    .entry => switch (current_tag.?) {
                        .title => constructTmpStr(&tmp_str, data),
                        // <link /> is void element
                        .link => {},
                        .id => current_entry.?.id = data,
                        .updated => current_entry.?.updated_raw = data,
                    },
                }
            },
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
    const result = try parseAtom(arena.allocator(), content);
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
    try std.testing.expectEqualDeep(expect_items[start..], result.items);
}
