const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const feed_types = @import("./feed_types.zig");
const RssDateTime = feed_types.RssDateTime;
const AtomDateTime = feed_types.AtomDateTime;
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const print = std.debug.print;
const datetime = @import("zig-datetime").datetime;

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

pub fn text_truncate(allocator: Allocator, text: []const u8) ![]const u8 {
    var arr = try std.ArrayList(u8).initCapacity(allocator, max_title_len);
    defer arr.deinit();

    var iter = mem.tokenizeAny(u8, text, &std.ascii.whitespace);
    if (iter.next()) |chunk| {
        arr.appendSliceAssumeCapacity(chunk[0..@min(chunk.len, max_title_len)]);
    }

    while (iter.next()) |chunk| {
        if (arr.capacity == arr.items.len) { break; }

        arr.appendAssumeCapacity(' ');
        const len = @min(chunk.len, arr.capacity - arr.items.len);
        arr.appendSliceAssumeCapacity(chunk[0..len]);
    }
        
    return arr.toOwnedSlice();
}

pub fn parseAtom(allocator: Allocator, content: []const u8) !FeedAndItems {
    var entries = try std.ArrayList(FeedItem).initCapacity(allocator, default_item_count);
    defer entries.deinit();
    var feed = Feed{ .feed_url = "" };
    var state: AtomParseState = .feed;
    var current_entry: FeedItem = .{ .title = "" };

    var doc = zig_xml.StaticDocument.init(content);
    var token_reader = doc.reader(allocator, .{});
    defer token_reader.deinit();

    var token = try token_reader.read();
    while (token != .eof) : (token = try token_reader.read()) {
        switch (token) {
            .eof => break,
            .element_start => {
                const tag = token_reader.elementName();

                if (AtomParseState.fromString(tag)) |new_state| {
                    state = new_state;
                }

                if (AtomParseTag.fromString(tag)) |new_tag| {
                   switch (state) {
                        .feed => switch (new_tag) {
                            .title => {
                                const text = try token_reader.readElementText();
                                feed.title = try text_truncate(allocator, text);
                            },
                            .link => {
                                const rel = blk: {
                                    if (token_reader.attributeIndex("rel")) |idx| {
                                        break :blk try token_reader.attributeValue(idx);
                                    }
                                    break :blk "alternate";
                                };

                                if (std.ascii.eqlIgnoreCase("alternate", rel)) {
                                    if (token_reader.attributeIndex("href")) |idx| {
                                        const value = try token_reader.attributeValue(idx);
                                        feed.page_url = mem.trim(u8, value, &std.ascii.whitespace);
                                    }
                                }
                            },
                            .updated => {
                                const date_raw = mem.trim(u8, try token_reader.readElementText(), &std.ascii.whitespace);
                                feed.updated_timestamp = AtomDateTime.parse(date_raw) catch null;
                            },
                            .published,
                            .id,
                            .icon => {},
                        },
                        .entry => switch (new_tag) {
                            .title => {
                                const text = try token_reader.readElementText();
                                current_entry.title = try text_truncate(allocator, text);
                            },
                            .link => {
                                const rel = blk: {
                                    if (token_reader.attributeIndex("rel")) |idx| {
                                        break :blk try token_reader.attributeValue(idx);
                                    }
                                    break :blk "alternate";
                                };

                                if (std.ascii.eqlIgnoreCase("alternate", rel)) {
                                    if (token_reader.attributeIndex("href")) |idx| {
                                        const value = try token_reader.attributeValue(idx);
                                        current_entry.link = mem.trim(u8, value, &std.ascii.whitespace);
                                    }
                                }
                            },
                            .id => {
                                if (token_reader.readElementText()) |id_raw| {
                                    current_entry.id = try allocator.dupe(u8, mem.trim(u8, id_raw, &std.ascii.whitespace));
                                } else |err| {
                                    std.log.warn("Failed to read entry's id from atom feed's entry. Error: {}", .{err});
                                }
                            },
                            .updated => {
                                const date_raw = mem.trim(u8, try token_reader.readElementText(), &std.ascii.whitespace);
                                current_entry.updated_timestamp = AtomDateTime.parse(date_raw) catch null;
                            },
                            .published,
                            .icon => {},
                        },
                    }
                }
            },
            .element_end => {
                const tag_str = token_reader.elementName();
                if (mem.eql(u8, "entry", tag_str)) {
                    add_or_replace_item(&entries, current_entry);
                    current_entry = .{ .title = "" };
                    state = .feed;
                    continue;
                }
            },
            .xml_declaration,
            .pi, .text,
            .entity_reference,
            .character_reference,
            .cdata,
            .comment => {},
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
        .title = "Atom-Powered Robots Run Amok Next line",
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

    var doc = zig_xml.StaticDocument.init(content);
    var token_reader = doc.reader(allocator, .{});
    defer token_reader.deinit();

    var is_guid_link = false;
    var guid_has_permalink = false;

    var token = try token_reader.read();
    while (token != .eof) : (token = try token_reader.read()) {
        switch (token) {
            .eof => break,
            .element_start => {
                const tag = token_reader.elementName();
                current_tag = RssParseTag.fromString(tag);
                if (RssParseState.fromString(tag)) |new_state| {
                    state = new_state;
                }
            },
            // .element_content => {
            //     const tag = current_tag orelse continue;
            //     const elem_content = token_reader.fullToken(token).element_content.content;

            //     switch (state) {
            //         .channel => switch (tag) {
            //             .title => try tmp_str.content_to_str(elem_content),
            //             .link => feed.page_url = try allocator.dupe(u8, mem.trim(u8, elem_content.text, &std.ascii.whitespace)),
            //             .pubDate => {
            //                 const date_raw = mem.trim(u8, elem_content.text, &std.ascii.whitespace);
            //                 feed.updated_timestamp = RssDateTime.parse(date_raw) catch 
            //                     AtomDateTime.parse(date_raw) catch null;
            //             },
            //             .@"dc:date" => {
            //                 feed.updated_timestamp = AtomDateTime.parse(mem.trim(u8, elem_content.text, &std.ascii.whitespace)) catch null;
            //             },
            //             .guid, .description, .url, .image => {},
            //         },
            //         .image => switch (tag){
            //             .url => {
            //                 if (feed.icon_url == null) {
            //                     feed.icon_url = try allocator.dupe(u8, mem.trim(u8, elem_content.text, &std.ascii.whitespace));
            //                 }
            //             },
            //             .title, .description, .link, .guid, .pubDate, .@"dc:date", .image => {}
            //         },
            //         .item => switch (tag) {
            //             .title => try tmp_str.content_to_str(elem_content),
            //             .description => if (current_item.title.len == 0) {
            //                 try tmp_str.content_to_str(elem_content);
            //             },
            //             .link, .guid => try tmp_str.content_to_str(elem_content),
            //             .pubDate => {
            //                 const date_raw = mem.trim(u8, elem_content.text, &std.ascii.whitespace);
            //                 current_item.updated_timestamp = RssDateTime.parse(date_raw) catch 
            //                     AtomDateTime.parse(date_raw) catch null;
            //             },
            //             .@"dc:date" => {
            //                 const date_raw = mem.trim(u8, elem_content.text, &std.ascii.whitespace);
            //                 current_item.updated_timestamp = AtomDateTime.parse(date_raw) catch null;
            //             },
            //             .url, .image => {}
            //         },
            //     }
            // },
            .element_end => {
                const tag_str = token_reader.elementName();
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
            // .element_end_empty => {
            //     current_tag = null;
            // },
            // .attribute_start => {
            //     if (current_item.link == null and state == .item) {
            //         const tag = current_tag orelse continue;
            //         if (tag == .guid) {
            //             const attr = token_reader.fullToken(token).attribute_start;
            //             guid_has_permalink = std.mem.eql(u8, attr.name, "isPermaLink");
            //         }
            //     }
            // },
            // .attribute_content => {
            //     // This means element is in <guid> and attribute is 'isPermaLink'. And
            //     // current_item.link == null
            //     if (guid_has_permalink) {
            //         const attr_content = token_reader.fullToken(token).attribute_content;
            //         is_guid_link = std.mem.eql(u8, attr_content.content.text, "true");
            //     }
            // },
            .xml_declaration, .comment, .pi, .text, .cdata, .character_reference, .entity_reference  => {},
        }
    }

    const items = try entries.toOwnedSlice();
    sortItems(items);

    return .{ .feed = feed, .items = items };
}

// Sorting item.updated_timestamp
// 1) if all values are null, no sorting
// 2) if mix of nulls and values push nulls to the bottom

fn sortItems(items: []FeedItem) void {
    var has_date = false;

    for (items) |item| {
        if (item.updated_timestamp != null) {
            has_date = true;
            break;
        }
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
    _ = expect_items; // autofix
    // 'start' is a runtime value. Need value to be runtime to coerce array
    // into a slice.
    var start: usize = 0;
    start = 0;
    // try std.testing.expectEqualDeep(expect_items[start..expect_items.len], result.items);
}

const super = @import("superhtml");

pub fn has_class(node: super.html.Ast.Node, code: []const u8, selector: []const u8) bool {
    if (selector[0] != '.' and selector.len <= 1) {
        return false;
    }
    var iter = node.startTagIterator(code, .html);
    while (iter.next(code)) |tag| {
        const name = tag.name.slice(code);
        if (!std.ascii.eqlIgnoreCase("class", name)) { continue; }

        if (tag.value) |value| {
            const expected_class_name = selector[1..];
            std.debug.assert(expected_class_name.len > 0);
            var token_iter = std.mem.tokenizeScalar(u8, value.span.slice(code), ' ');
            while (token_iter.next()) |class_name| {
                if (std.ascii.eqlIgnoreCase(expected_class_name, class_name)) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn text_from_node(allocator: std.mem.Allocator, ast: super.html.Ast, code: []const u8, node: super.html.Ast.Node) !?[]const u8 {
    var iter_text_node = IteratorTextNode.init(ast, code, node);
    var text_arr = try std.BoundedArray(u8, max_title_len).init(0);
    blk: while (iter_text_node.next()) |text_node| {
        const text = std.mem.trim(u8, text_node.open.slice(code), &std.ascii.whitespace);
        var token_iter = std.mem.tokenizeAny(u8, text, &std.ascii.whitespace);
        if (token_iter.next()) |word_first| {
            if (text_arr.len != 0) {
                text_arr.append(' ') catch break :blk;
            }
            text_arr.appendSlice(word_first) catch {
                text_arr.appendSliceAssumeCapacity(word_first[0..text_arr.buffer.len - text_arr.len]);
                break :blk;
            };

            while (token_iter.next()) |word| {
                text_arr.append(' ') catch break :blk;
                text_arr.appendSlice(word) catch {
                    text_arr.appendSliceAssumeCapacity(word[0..text_arr.buffer.len - text_arr.len]);
                    break :blk;
                };
            }
        }
    }

    if (text_arr.len > 0) {
        return try allocator.dupe(u8, text_arr.slice());
    }

    return null;
}

const IteratorTextNode = struct {
    ast: super.html.Ast,
    code: []const u8,
    next_index: usize,
    end_index: usize,

    pub fn init(ast: super.html.Ast, code: []const u8, start_node: super.html.Ast.Node) @This() {
        // exclusive
        const end_index = blk: {
            if (start_node.next_idx != 0) {
                break :blk start_node.next_idx;
            }

            var parent = start_node.parent_idx;
            while (parent != 0) {
                const node = ast.nodes[parent];
                if (node.next_idx != 0) {
                    break :blk node.next_idx;
                }
                parent = node.parent_idx;
            }

            break :blk ast.nodes.len;
        };

        return .{
            .ast = ast,
            .code = code,
            .next_index = start_node.first_child_idx,
            .end_index = end_index,
        };
    }

    pub fn next(self: *@This()) ?super.html.Ast.Node {
        if (self.next_index == 0 or self.next_index >= self.ast.nodes.len) {
            return null;
        }

        for (self.ast.nodes[self.next_index..self.end_index], self.next_index..) |node, index| {
            if (node.kind != .text) { continue; }
            self.next_index = index + 1;
            return node;
        }

        return null;
    }
};

const NodeIterator = struct {
    next_index: usize,
    end_index: usize,
    selector_iter: Selector,
    ast: super.html.Ast,
    code: []const u8,

    pub fn init(ast: super.html.Ast, code: []const u8, start_node: super.html.Ast.Node, selector: []const u8) @This() {
        std.debug.assert(selector.len > 0);

        // exclusive
        const end_index = blk: {
            if (start_node.next_idx != 0) {
                break :blk start_node.next_idx;
            }

            var parent = start_node.parent_idx;
            while (parent != 0) {
                const node = ast.nodes[parent];
                if (node.next_idx != 0) {
                    break :blk node.next_idx;
                }
                parent = node.parent_idx;
            }

            break :blk ast.nodes.len;
        };

        return .{
            .ast = ast,
            .code = code,
            .next_index = start_node.first_child_idx,
            .end_index = end_index,
            .selector_iter = Selector.init(selector),
        };
    }
    
    pub fn next(self: *@This()) ?super.html.Ast.Node {
            if (self.next_index == 0 or self.next_index >= self.ast.nodes.len) {
            return null;
        }
        
        var selector_iter = self.selector_iter;
        const last_selector = selector_iter.next() orelse return null;
        const is_class = last_selector[0] == '.';

        const start_index = self.next_index;
        const end_idx = self.end_index;

        for (self.ast.nodes[start_index..end_idx], start_index..) |n, index| {
            if (n.kind != .element and n.kind != .element_void and n.kind != .element_self_closing) {
                continue;
            }

            const span = n.open.getName(self.code, .html);
            const is_match = blk: {
                if (is_class and has_class(n, self.code, last_selector)) {
                    break :blk is_selector_match(self.ast, self.code, selector_iter, n);
                } else if (std.ascii.eqlIgnoreCase(last_selector, span.slice(self.code))) {
                    // var copy_iter = selector_iter;
                    break :blk is_selector_match(self.ast, self.code, selector_iter, n);
                }
                break :blk false;
            };
            if (is_match) {
                self.next_index = index + 1;
                return n;
            }
        }

        return null;
    }
};

pub fn is_selector_match(ast: super.html.Ast, code: []const u8, selector_iter: Selector, node: super.html.Ast.Node) bool {
    var parent_index = node.parent_idx;
    var iter = selector_iter;
    while (iter.next()) |selector| {
        const is_class = selector[0] == '.';
        while (parent_index != 0) {
            const current = ast.nodes[parent_index];
            parent_index = current.parent_idx;
            
            if (is_class and has_class(current, code, selector)) {
                break;
            } else if (std.ascii.eqlIgnoreCase(selector, current.open.getName(code, .html).slice(code))) {
                break;
            }
        }
        if (parent_index == 0) {
            return false;
        }
    }
    return true;
}

const HtmlOptions = struct {
    selector_container: []const u8,
    selector_link: ?[]const u8 = null,
    selector_heading: ?[]const u8 = null,
    selector_date: ?[]const u8 = null,
};

const Selector = struct {
    iter: std.mem.SplitBackwardsIterator(u8, .scalar), 

    pub fn init(input: []const u8) @This() {
        return .{
            .iter = std.mem.splitBackwardsScalar(u8, input, ' '),
        };
    }

    pub fn next(self: *@This()) ?[]const u8 {
        while (self.iter.next()) |val| {
            if (val.len == 0) {
                continue;
            }
            return val;
        }
        return null;
    }
};

pub fn is_single_selector_match(content: []const u8, node: super.html.Ast.Node, selector: []const u8) bool {
    const trimmed = mem.trim(u8, selector, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return false;
    }

    if (mem.indexOfScalar(u8, trimmed, ' ')) |count| if (count == 0) {
        return has_class(node, content, trimmed) or mem.eql(u8, node.open.slice(content), trimmed);
    };
    return false;
}

// TODO: add date_format HtmlOption
pub fn parse_html(allocator: Allocator, content: []const u8, html_options: HtmlOptions) !FeedAndItems {
    const ast = try super.html.Ast.init(allocator, content, .html);
    if (ast.errors.len > 0) {
        std.log.warn("Html contains {d} parsing error(s). Will try to find feed item anyway.", .{ast.errors.len});
        // ast.printErrors(code, "<STRING>");
    }

    var feed: Feed = .{ .feed_url = undefined };
    const root_node = ast.nodes[0];
    // ast.debug(content);

    var title_iter = NodeIterator.init(ast, content, root_node, "title");
    if (title_iter.next()) |n| {
        feed.title = try text_from_node(allocator, ast, content, n);
    }

    var container_iter = NodeIterator.init(ast, content, ast.nodes[0], html_options.selector_container);

    var feed_items = try std.ArrayList(FeedItem).initCapacity(allocator, default_item_count);
    defer feed_items.deinit();

    while (container_iter.next()) |node_container| {
        var item_link: ?[]const u8 = null;
        var item_title: ?[]const u8 = null;
        const node = node_container;

        const link_node = blk: {
            if (html_options.selector_link) |selector| {
                if (is_single_selector_match(content, node, selector)) {
                    break :blk node;
                }
                var iter = NodeIterator.init(ast, content, node, selector);
                if (iter.next()) |n| {
                    break :blk n;
                } else {
                    std.log.warn("Could not find link node with selector '{s}'", .{selector});
                }
            }

            if (is_single_selector_match(content, node, "a")) {
                break :blk node;
            }

            var iter = NodeIterator.init(ast, content, node, "a");
            break :blk iter.next();
        };

        if (link_node) |n| {
            var attr_iter = n.startTagIterator(content, .html);
            while (attr_iter.next(content)) |attr| {
                if (attr.value) |value| {
                    const name = attr.name.slice(content);
                    if (std.ascii.eqlIgnoreCase("href", name)) {
                        item_link = value.span.slice(content);
                    }
                }
            }

            if (try text_from_node(allocator, ast, content, n)) |text| {
                item_title = text;
            }
        }

        if (html_options.selector_heading) |heading| {
            if (is_single_selector_match(content, node, heading)) {
                if (try text_from_node(allocator, ast, content, node)) |text| {
                    item_title = text;
                }
            } else {
                var heading_iter = NodeIterator.init(ast, content, node, heading);
                if (heading_iter.next()) |node_match| {
                    if (try text_from_node(allocator, ast, content, node_match)) |text| {
                        item_title = text;
                    }
                } else {
                    std.log.warn("Could not find heading node with selector '{s}'", .{heading});
                }
            }
        }

        if (item_title == null) {
            for (&[_][]const u8{"h1", "h2", "h3", "h4", "h5", "h6"}) |tag| {
                if (is_single_selector_match(content, node, tag)) {
                    if (try text_from_node(allocator, ast, content, node)) |text| {
                        item_title = text;
                        break;
                    }
                }

                var heading_iter = NodeIterator.init(ast, content, node, tag);
                if (heading_iter.next()) |node_match| {
                    if (try text_from_node(allocator, ast, content, node_match)) |text| {
                        item_title = text;
                        break;
                    }
                }
            }
        }

        // Find any text inside node
        if (item_title == null) {
            if (try text_from_node(allocator, ast, content, node)) |text| {
                item_title = text;
            }
        }
        
        var item_updated_ts: ?i64 = null;
        const time_node: ?super.html.Ast.Node = blk: {
            if (html_options.selector_date) |selector| {
                var iter = NodeIterator.init(ast, content, node, selector);
                if (iter.next()) |n| {
                    break :blk n;
                } else {
                    std.log.warn("Could not find date node with selector '{s}'", .{selector});
                }
            }

            var iter = NodeIterator.init(ast, content, node, "time");
            break :blk iter.next();
        };

        if (time_node) |n| {
            var value_raw: ?[]const u8 = null;

            if (std.ascii.eqlIgnoreCase("time", n.open.slice(content))) {
                var attr_iter = n.startTagIterator(content, .html);
                while (attr_iter.next(content)) |attr| {
                    if (attr.value) |value| {
                        const name = attr.name.slice(content);
                        if (std.ascii.eqlIgnoreCase("datetime", name)) {
                            value_raw = value.span.slice(content);
                        }
                    }
                }
            }

            if (value_raw == null) {
                if (n.first_child_idx != 0) {
                    const child_node = ast.nodes[n.first_child_idx];
                    if (child_node.first_child_idx == 0 and child_node.next_idx == 0 and child_node.kind == .text) {
                        value_raw = child_node.open.slice(content);
                    }
                }
            }

            if (value_raw) |raw| {
                item_updated_ts = seconds_from_datetime(mem.trim(u8, raw, &std.ascii.whitespace));
            }
        }

        feed_items.appendAssumeCapacity(.{
            .title = item_title orelse "",
            .link = item_link,
            .updated_timestamp = item_updated_ts,
        });

        if (feed_items.items.len == default_item_count) {
            break;
        }
    }

    return .{
        .feed = feed,
        .items = try feed_items.toOwnedSlice(),
    };
}

// NOTE: <time> valid set of date formats 
// https://developer.mozilla.org/en-US/docs/Web/HTML/Element/time
pub fn seconds_from_datetime(raw: []const u8) ?i64 {
    if (raw.len == 4) {
        // - YYYY
        const year = std.fmt.parseUnsigned(u16, raw, 10) catch {
            std.log.warn("Failed to parse 4 character length value '{s}' to year.", .{raw});
            return null;
        };
        const date: datetime.Date = .{.year = year };
        return @intFromFloat(date.toSeconds());
    }

    const dash_count = mem.count(u8, raw, "-");
    const iso_len = 10;
    const date = blk: { 
        if (dash_count > 0) {
            if (dash_count == 2 and raw.len >= iso_len) {
                break :blk datetime.Date.parseIso(raw[0..iso_len]) catch {
                    std.log.warn("Failed to parse full date from date format 'YYYY-MM-DD'. Failed input '{s}'", .{raw});
                    return null;
                };
            } else if (dash_count == 1) {
                if (raw.len == 5 and raw[2] == '-') {
                    // - MM-DD
                    const month = std.fmt.parseUnsigned(u4, raw[0..2], 10) catch {
                        std.log.warn("Failed to parse month from date format 'MM-DD'. Failed input '{s}'", .{raw});
                        return null;
                    };

                    const day = std.fmt.parseUnsigned(u8, raw[3..], 10) catch {
                        std.log.warn("Failed to parse day from date format 'MM-DD'. Failed input '{s}'", .{raw});
                        return null;
                    };
                
                    var date = datetime.Date.now();
                    date.month = month;
                    date.day = day;
                    break :blk date;
                } else if (raw.len == 7 and raw[4] == '-') {
                    // - YYYY-MM
                    const year = std.fmt.parseUnsigned(u16, raw[0..4], 10) catch {
                        std.log.warn("Failed to parse year from date format 'YYYY-MM'. Failed input '{s}'", .{raw});
                        return null;
                    };

                    const month = std.fmt.parseUnsigned(u4, raw[5..], 10) catch {
                        std.log.warn("Failed to parse month from date format 'YYYY-MM'. Failed input '{s}'", .{raw});
                        return null;
                    };
                
                    break :blk datetime.Date{.year = year, .month = month};
                } else if (raw.len == 8 and raw[4] == '-' and raw[5] == 'W') {
                    // - YYYY-WWW
                    const year = std.fmt.parseUnsigned(u16, raw[0..4], 10) catch {
                        std.log.warn("Failed to parse year from date format 'YYYY-WWW'. Failed input '{s}'", .{raw});
                        return null;
                    };

                    const weeks = std.fmt.parseUnsigned(u16, raw[6..], 10) catch {
                        std.log.warn("Failed to parse weeks from date format 'YYYY-WWW'. Failed input '{s}'", .{raw});
                        return null;
                    };

                    var date = datetime.Date{.year = year};
                    if (weeks > 2) {
                        date = date.shiftDays((weeks - 1) * 7);
                    }
                    break :blk date;
                }
            
            }
        }
        break :blk null;
    };

    if (date == null) {
        return null;
    }

    var dt: datetime.Datetime = .{
        .date = date.?,
        .time = .{},
        .zone = &datetime.timezones.Zulu,
    };

    const rest = mem.trimLeft(u8, raw[iso_len..], " T");
    const time_end = mem.indexOfAny(u8, rest, ".+-Z") orelse rest.len;
    const time_raw = rest[0..time_end];
    print("|{s}|\n", .{time_raw});

    var timezone: ?datetime.Timezone = null;
    if (time_raw.len > 0) {
        var time_iter = mem.splitScalar(u8, time_raw, ':');
        var has_time = false;
        if (time_iter.next()) |hours_str| {
            if (std.fmt.parseUnsigned(u8, hours_str, 10)) |hour| {
                dt.time.hour = hour;
            } else |_| {
                std.log.warn("Failed to parse hours from input '{s}'", .{raw});
            }
        }

        if (time_iter.next()) |minutes_str| {
            if (std.fmt.parseUnsigned(u8, minutes_str, 10)) |minute| {
                dt.time.minute = minute;
            } else |_| {
                std.log.warn("Failed to parse minutes from input '{s}'", .{raw});
            }
            has_time = true;
        }

        if (time_iter.next()) |seconds_str| {
            if (std.fmt.parseUnsigned(u8, seconds_str, 10)) |second| {
                dt.time.second = second;
            } else |_| {
                std.log.warn("Failed to parse seconds from input '{s}'", .{raw});
            }
        }
    
        if (has_time) {
            var timezone_offset: i16 = 0;
            if (mem.indexOfAny(u8, rest[time_end..], "-+")) |index| {
                var current_str = rest[time_end + index + 1 ..];
                if (std.fmt.parseUnsigned(u8, current_str[0..2], 10)) |hour| {
                    timezone_offset += hour * 60;
                } else |_| {
                    std.log.warn("Failed to parse timezone hours from input '{s}'", .{raw});
                }

                const next_start: u8 = if (current_str[2] == ':') 3 else 2;
                const timezone_name = current_str[0..next_start+2];
                if (std.fmt.parseUnsigned(u8, current_str[next_start..next_start+2], 10)) |minute| {
                    timezone_offset += minute;
                } else |_| {
                    std.log.warn("Failed to parse timezone minutes from input '{s}'", .{raw});
                }

                timezone = datetime.Timezone.create(timezone_name, timezone_offset);
            }
        }
    }

    if (timezone) |zone| {
        dt.zone = &zone;
    }

    return @intCast(@divFloor(dt.toTimestamp(), 1000));
}

pub const ContentType = feed_types.ContentType;

pub fn getContentType(allocator: Allocator, content: []const u8) ?ContentType {
    var doc = zig_xml.StaticDocument.init(content);
    var r = doc.reader(allocator, .{});
    defer r.deinit();

    var depth: usize = 0;
    while (depth < 2) {
        const token = r.read() catch break;
        if (token == .element_start) {
            const tag = r.elementName();

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
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rss =
        \\<?xml version="1.0"?>
        \\<rss version="2.0">
        \\   <channel>
        \\   </channel>
        \\</rss>
    ;
    const rss_type = getContentType(alloc, rss);
    try std.testing.expectEqual(ContentType.rss, rss_type.?);

    const atom =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\</feed>
    ;
    const atom_type = getContentType(alloc, atom);
    try std.testing.expectEqual(ContentType.atom, atom_type.?);

    const html_raw =
        \\<!DOCTYPE html>
    ;
    const html_type = getContentType(alloc, html_raw);
    try std.testing.expectEqual(ContentType.html, html_type.?);
}

pub fn parse(allocator: Allocator, content: []const u8, content_type: ?ContentType) !FeedAndItems {
    _ = content_type;

    // Figure out content type based on file content
    // Server might return wrong content type. Like 'https://jakearchibald.com/'
    const ct = getContentType(allocator, content) orelse return error.UnknownContentType;
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

pub const std_options: std.Options = .{
    // This sets log level based on scope.
    // This overrides global log_level
    .log_scope_levels = &.{ 
        .{.level = .err, .scope = .@"html/tokenizer"},
        .{.level = .err, .scope = .@"html/ast"} 
    },
    // This set global log level
    .log_level = .debug,
};


pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // const content = @embedFile("tmp_file");
    const content = 
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\ <title>page title</title>
    \\</head>
    \\<body>
    \\  <div class="post">
    \\    <!-- comment -->
    \\    <input type="text" value="foo">
    \\    <p class="paragraph">foo bar</p>
    \\    <span>2020</span>
    \\    <p>
    \\      <a href="#item1">
    \\        text
    \\        more text in here
    \\        <span>link</span>
    \\        <span>second</span>
    \\        hello
    \\      </a>
    \\    </p>
    \\  </div>
    \\  <div class="post">
    \\    second post
    \\  </div>
    \\  <p>other paragraph</p>
    \\</body>
    \\</html>
    ;
    const html_options: HtmlOptions = .{
        .selector_container = ".post",
        .selector_date = "span",
    };
    const feed = try parse_html(alloc, content, html_options);
    // print("feed {}\n", .{feed});
    print("feed.len {}\n", .{feed.items.len});
    // print("\n==========> START {d}\n", .{feed.items.len});
    // print("feed.icon_url: |{?s}|\n", .{feed.feed.icon_url});
    // for (feed.items) |item| {
    //     print("title: |{s}|\n", .{item.title});
    //     print("link: |{?s}|\n", .{item.link});
    //     print("date: {?d}\n", .{item.updated_timestamp});
    //     print("\n", .{});
    // }
}

