const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const feed_types = @import("./feed_types.zig");
const RssDateTime = feed_types.RssDateTime;
const AtomDateTime = feed_types.AtomDateTime;
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const print = std.debug.print;
const dt = @import("zig-datetime"); 
const datetime = dt.datetime;
const assert = std.debug.assert;
const Uri = std.Uri;
const util = @import("util.zig"); 
const is_url = util.is_url; 

pub const std_options: std.Options = .{
    // This sets log level based on scope.
    // This overrides global log_level
    // .log_scope_levels = &.{ 
    //     .{.level = .info, .scope = .@"html/tokenizer"},
    //     .{.level = .info, .scope = .@"html/ast"} 
    // },
    // This set global log level
    .log_level = .info,
};

const max_title_len = 512;
const default_item_count = @import("./app_config.zig").max_items;

items: std.BoundedArray(FeedItem.Parsed, default_item_count),
doc: zig_xml.StaticDocument,
token_reader: zig_xml.GenericReader(error{}),
text_arr: std.ArrayListUnmanaged(u8) = .empty,
allocator: Allocator,
content_type: ContentType,

pub fn init(allocator: Allocator, content: []const u8) !@This() {
    // Server might return wrong content/file type for content. Like: 'https://jakearchibald.com/'
    const ct = getContentType(mem.trim(u8, content, &std.ascii.whitespace)) orelse return error.UnknownContentType;

    var doc = zig_xml.StaticDocument.init(content);
    return .{
        .items = try .init(0),
        .doc = doc,
        .token_reader = doc.reader(allocator, .{ .namespace_aware = false, }),
        .allocator = allocator,
        .content_type = ct,
    };
}

pub fn deinit(self: *@This(), allocator: Allocator) void {
    _ = allocator;
    self.token_reader.deinit();
}

pub fn text_loc(self: *@This()) !feed_types.Location {
    const start = self.text_arr.items.len;
    const text = mem.trim(u8, try self.token_reader.readElementText(), &std.ascii.whitespace);
    try self.text_arr.appendSlice(self.allocator, text);
    return .{.offset = @intCast(start), .len = @intCast(self.text_arr.items.len - start)};
}

pub fn attr_loc(self: *@This(), attr_key: []const u8) !?feed_types.Location {
    if (self.token_reader.attributeIndex(attr_key)) |idx| {
        const start = self.text_arr.items.len;
        const value = mem.trim(u8, try self.token_reader.attributeValue(idx), &std.ascii.whitespace);
        try self.text_arr.appendSlice(self.allocator, value);
        return .{.offset = @intCast(start), .len = @intCast(self.text_arr.items.len - start)};
    }

    return null;
}


pub fn slice_from_loc(self: *@This(), loc: feed_types.Location) []const u8 {
    const loc_source = if (self.content_type == .html) self.doc.data else self.text_arr.items;
    return loc_source[loc.offset..loc.offset + loc.len];
}

pub const ParsedFeed = struct {
    feed: Feed.Parsed,
    items: []FeedItem.Parsed,
    html_opts: ?HtmlOptions = null,
    item_interval: i64 = feed_types.seconds_in_10_days,
};

pub const ValidFeed = struct {
    feed: Feed,
    items: []FeedItem = &.{},
    html_opts: ?HtmlOptions = null,
    item_interval: i64 = feed_types.seconds_in_10_days,
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

pub fn html_escape(allocator: Allocator, input: []const u8) ![]const u8 {
    const symbols = [_]u8{   '&',   '<',  '>',  '"',   '\''};
    const entities = [_][]const u8{"&amp;", "&lt;", "&gt;", "&quot;", "&#39;"};
    var new_size = input.len;
    for (symbols, entities) |sym, ent| {
        new_size += mem.replacementSize(u8, input, &.{sym}, ent) - input.len;
    }
    if (input.len == new_size) {
        return input;
    }
    var arr = try std.ArrayList(u8).initCapacity(allocator, new_size);
    defer arr.deinit();

    var pos: usize = 0;
    while (mem.indexOfAnyPos(u8, input, pos, &symbols)) |index| {
        arr.appendSliceAssumeCapacity(input[pos..index]);
        const ent = blk: {
            for (symbols, entities) |sym, ent| {
                if (sym == input[index]) {
                    break :blk ent;
                }
            }
            unreachable;
        };
        arr.appendSliceAssumeCapacity(ent);
        pos = index + 1;
    }
    arr.appendSliceAssumeCapacity(input[pos..]);

    return arr.toOwnedSlice();
}

// https://html.spec.whatwg.org/multipage/syntax.html#syntax-charref
pub fn html_unescape(writer: anytype, input: []const u8) ![]const u8 {
    const entities = [_][]const u8{"amp", "lt", "gt", "quot", "apos", "nbsp"};
    const raws = [_][]const u8{    "&",   "<",  ">",  "\"",   "'",    " "};

    const items_start = writer.context.items.len;
    var buf_index_start: usize = 0;

    while (mem.indexOfScalarPos(u8, input, buf_index_start, '&')) |index| {
        try writer.writeAll(input[buf_index_start..index]);
        buf_index_start = index + 1;
        const start = buf_index_start;
        if (start >= input.len) { break; }

        if (input[start] == '#') {
            // numeric entities
            var nr_start = start + 1; 
            buf_index_start = mem.indexOfScalarPos(u8, input, nr_start, ';') orelse break;
            const is_hex = input[nr_start] == 'x' or input[nr_start] == 'X';
            nr_start += @intFromBool(is_hex);
            const value = input[nr_start..buf_index_start];
            buf_index_start += 1;
            if (value.len == 0) { continue; }

            const base: u8 = if (is_hex) 16 else 10;
            const nr = std.fmt.parseUnsigned(u21, value, base) catch continue;
            var buf_cp: [4]u8 = undefined;
            const cp = std.unicode.utf8Encode(nr, &buf_cp) catch continue;
            try writer.writeAll(buf_cp[0..cp]);
        } else {
            // named entities
            const index_opt: ?usize = blk: {
                for (entities, 0..) |entity, i| {
                    if (mem.startsWith(u8, input[start..], entity) and
                        start + entity.len < input.len and input[start + entity.len] == ';'
                    ) {
                        break :blk i;
                    }
                }

                break :blk null;
            };

            if (index_opt) |i| {
                buf_index_start += entities[i].len + 1;
                try writer.writeAll(raws[i]);
            }
        }
    }
    try writer.writeAll(input[buf_index_start..]);
    return writer.context.items[items_start..];
}

pub fn text_truncate_alloc(allocator: Allocator, text: []const u8) ![]const u8 {
    var input = mem.trim(u8, text, &std.ascii.whitespace);
    if (input.len == 0) {
        return "";
    }

    var arr = try std.ArrayList(u8).initCapacity(allocator, max_title_len);
    defer arr.deinit();

    if (mem.indexOfScalar(u8, input, '&') != null and mem.indexOfScalar(u8, input, ';') != null) {
        input = try html_unescape(arr.writer(), input);
    }

    const ast = try super.html.Ast.init(allocator, input, .html);
    defer ast.deinit(allocator);
    if (ast.errors.len == 0) {
        input = try text_from_node(allocator, ast, input, ast.nodes[0]);
    } else {
        std.log.warn("Possible invalid html: '{s}'", .{input});
    }

    var out = try std.ArrayList(u8).initCapacity(allocator, max_title_len);
    defer out.deinit();

    var iter = mem.tokenizeAny(u8, input, &std.ascii.whitespace);
    if (iter.next()) |first| {
        out.appendSliceAssumeCapacity(first[0..@min(first.len, max_title_len)]);

        while (iter.next()) |chunk| {
            if (out.capacity == out.items.len) { break; }

            out.appendAssumeCapacity(' ');
            const len = @min(chunk.len, out.capacity - out.items.len);
            out.appendSliceAssumeCapacity(chunk[0..len]);
        }
    }
        
    return out.toOwnedSlice();
}

pub fn parseAtom(self: *@This()) !ParsedFeed {
    var feed = Feed.Parsed{};
    var state: AtomParseState = .feed;
    var current_entry: FeedItem.Parsed = .{};

    var token = try self.token_reader.read();
    while (token != .eof) : (token = try self.token_reader.read()) {
        switch (token) {
            .eof => break,
            .element_start => {
                const tag = self.token_reader.elementName();

                if (AtomParseState.fromString(tag)) |new_state| {
                    state = new_state;
                }

                if (AtomParseTag.fromString(tag)) |new_tag| {
                   switch (state) {
                        .feed => switch (new_tag) {
                            .title => {
                                feed.title = try self.text_loc();
                            },
                            .link => {
                                const rel = blk: {
                                    if (self.token_reader.attributeIndex("rel")) |idx| {
                                        break :blk try self.token_reader.attributeValue(idx);
                                    }
                                    break :blk "alternate";
                                };

                                if (std.ascii.eqlIgnoreCase("alternate", rel)) {
                                    if (try self.attr_loc("href")) |loc| {
                                        feed.page_url = loc;
                                    }
                                }
                            },
                            .updated => {
                                const date_raw = mem.trim(u8, try self.token_reader.readElementText(), &std.ascii.whitespace);
                                feed.updated_timestamp = AtomDateTime.parse(date_raw) catch null;
                            },
                            .published,
                            .id,
                            .icon => {},
                        },
                        .entry => switch (new_tag) {
                            .title => {
                                current_entry.title = try self.text_loc();
                            },
                            .link => {
                                const rel = blk: {
                                    if (self.token_reader.attributeIndex("rel")) |idx| {
                                        break :blk try self.token_reader.attributeValue(idx);
                                    }
                                    break :blk "alternate";
                                };

                                if (std.ascii.eqlIgnoreCase("alternate", rel)) {
                                    if (try self.attr_loc("href")) |loc| {
                                        current_entry.link = loc;
                                    }
                                }
                            },
                            .id => {
                                if (self.text_loc()) |loc| {
                                    current_entry.id = loc;
                                } else |err| {
                                    std.log.warn("Failed to read entry's id from atom feed's entry. Error: {}", .{err});
                                }
                            },
                            .published => {
                                const date_raw = mem.trim(u8, try self.token_reader.readElementText(), &std.ascii.whitespace);
                                if (AtomDateTime.parse(date_raw)) |new_date| {
                                    current_entry.updated_timestamp = new_date;
                                } else |err| {
                                    std.log.warn("Failed to parse atom date: '{s}'. Error: {}", .{date_raw, err});
                                }
                            },
                            .updated => if (current_entry.updated_timestamp == null) {
                                const date_raw = mem.trim(u8, try self.token_reader.readElementText(), &std.ascii.whitespace);
                                if (AtomDateTime.parse(date_raw)) |new_date| {
                                    current_entry.updated_timestamp = new_date;
                                } else |err| {
                                    std.log.warn("Failed to parse atom date: '{s}'. Error: {}", .{date_raw, err});
                                }
                            },
                            .icon => {},
                        },
                    }
                }
            },
            .element_end => {
                const tag_str = self.token_reader.elementName();
                if (mem.eql(u8, "entry", tag_str)) {
                    add_or_replace_item(&self.items, current_entry);
                    current_entry = .{ .title = null };
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


    return .{ .feed = feed, .items = self.items.slice() };
}

test "parseAtom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = @embedFile("atom.atom");
    const result = try parse(arena.allocator(), content, null);
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

pub fn parseRss(self: *@This()) !ParsedFeed {
    var feed: Feed.Parsed = .{};
    var state: RssParseState = .channel;
    var state_item: ?RssParseTag = null;
    var current_item: FeedItem.Parsed = .{};

    var token = try self.token_reader.read();
    while (token != .eof) : (token = try self.token_reader.read()) {
        switch (token) {
            .eof => break,
            .element_start => {
                const tag = self.token_reader.elementName();
                if (RssParseState.fromString(tag)) |new_state| {
                    state = new_state;
                }

                state_item = RssParseTag.fromString(tag);
                if (state_item) |new_tag| {
                    switch (state) {
                        .channel => switch (new_tag) {
                            .title => {
                                feed.title = try self.text_loc();
                            },
                            .link => {
                                feed.page_url = try self.text_loc();
                            },
                            .pubDate, .@"dc:date" => {
                                const date_raw = try self.token_reader.readElementText();
                                const date_str = mem.trim(u8, date_raw, &std.ascii.whitespace);
                                feed.updated_timestamp = RssDateTime.parse(date_str) catch 
                                    AtomDateTime.parse(date_str) catch
                                    parse_wrong_rss_date(date_str) orelse null;
                            },
                            .guid, .description, .url, .image => {},
                        },
                        .item => switch (new_tag) {
                            .title => {
                                current_item.title = try self.text_loc();
                            },
                            .description => {
                                if (current_item.title == null) {
                                    current_item.title = try self.text_loc();
                                }
                            },
                            .guid => {
                                current_item.id = try self.text_loc();
                            },
                            .link => {
                                current_item.link = try self.text_loc();
                            },
                            .pubDate, .@"dc:date" => {
                                const date_raw = try self.token_reader.readElementText();
                                const date_str = mem.trim(u8, date_raw, &std.ascii.whitespace);
                                current_item.updated_timestamp = RssDateTime.parse(date_str) catch 
                                    AtomDateTime.parse(date_str) catch
                                    parse_wrong_rss_date(date_str) orelse null;
                            },
                            .url, .image => {},
                        },
                        // TODO: remove .image?
                        .image => switch (new_tag) {
                            .url => {},
                            .title, .description, .link, .guid, .pubDate, .@"dc:date", .image => {}
                        },
                    }
                }
            },
            .element_end => {
                const tag_str = self.token_reader.elementName();
                if (mem.eql(u8, "item", tag_str)) {
                    add_or_replace_item(&self.items, current_item);
                    current_item = .{};
                    state = .channel;
                    state_item = null;
                    continue;
                } else if (mem.eql(u8, "image", tag_str)) {
                    state = .channel;
                    continue;
                }
            },
            .text => {},
            .xml_declaration, .comment, .pi, .cdata, .character_reference, .entity_reference  => {},
        }
    }

    return .{ .feed = feed, .items = self.items.slice() };
}

// Sorting item.updated_timestamp
// 1) if all values are null, no sorting
// 2) if mix of nulls and values push nulls to the bottom

fn sortItems(items: []FeedItem.Parsed) void {
    var has_date = false;

    for (items) |item| {
        if (item.updated_timestamp != null) {
            has_date = true;
            break;
        }
    }

    if (has_date) {
        const S = struct {
            pub fn less_than(_: void, lhs: FeedItem.Parsed, rhs: FeedItem.Parsed) bool {
                const lhs_ts = lhs.updated_timestamp orelse return false;
                const rhs_ts = rhs.updated_timestamp orelse return true;
                return lhs_ts > rhs_ts;
            }
        };

        mem.sort(FeedItem.Parsed, items, {}, S.less_than);
    }
}

fn add_or_replace_item(entries: *std.BoundedArray(FeedItem.Parsed, default_item_count), current_item: FeedItem.Parsed) void {
    const items = entries.constSlice();
    if (entries.constSlice().len == default_item_count) {
        if (current_item.updated_timestamp) |current_ts| {
            var iter = std.mem.reverseIterator(items);
            var oldest_ts: ?i64 = null;
            const oldest: ?FeedItem.Parsed = iter.next();
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
                    entries.replaceRange(replace_index, 1, &[_]FeedItem.Parsed{current_item}) catch unreachable;
                }
            } else {
                entries.replaceRange(replace_index, 1, &[_]FeedItem.Parsed{current_item}) catch unreachable;
            }
        }
    } else {
        entries.appendAssumeCapacity(current_item);
    }    
}

test "parseRss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = @embedFile("rss2.xml");
    const result = try parse(arena.allocator(), content, null);
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

fn text_from_node(allocator: Allocator, ast: super.html.Ast, code: []const u8, node: super.html.Ast.Node) ![]const u8 {
    var iter_text_node = IteratorTextNode.init(ast, code, node);
    var text_arr = try std.BoundedArray(u8, max_title_len).init(0);
    blk: while (iter_text_node.next()) |text_node| {
        const open_span = text_node.open;
        const text = open_span.slice(code);
        if (text_arr.len > 0 and 
            text_arr.get(text_arr.len - 1) != ' ' and
            iter_text_node.has_space()) {
            text_arr.append(' ') catch break :blk;
        }

        // Collapse whitespace (expect space) to one space
        const whitespace = [_]u8{ '\t', '\n', '\r', std.ascii.control_code.vt, std.ascii.control_code.ff };
        var token_iter = std.mem.tokenizeAny(u8, text, &whitespace);
        if (token_iter.next()) |word_first| {
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

    if (text_arr.len == 0) {
        return "";
    }

    return try allocator.dupe(u8, text_arr.slice());
}

fn text_location_from_node(ast: super.html.Ast, code: []const u8, node: super.html.Ast.Node) !?feed_types.Location {
    var iter_text_node = IteratorTextNode.init(ast, code, node);

    const start, var end = if (iter_text_node.next()) |text_node| 
        .{ text_node.open.start, text_node.open.end }
    else return null;

    while (iter_text_node.next()) |text_node| {
        end = text_node.open.end;
    }

    return feed_types.Location{.offset = start, .len = end - start };
}

const IteratorTextNode = struct {
    ast: super.html.Ast,
    code: []const u8,
    next_index: usize,
    end_index: usize,
    has_prev_space: bool = false,

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
        self.has_prev_space = false;
        if (self.next_index == 0 or self.next_index >= self.ast.nodes.len) {
            return null;
        }

        for (self.ast.nodes[self.next_index..self.end_index], self.next_index..) |node, index| {
            if (!self.has_prev_space) {
                if (node.open.start > 0 and 
                 (self.code[node.open.start - 1] == ' ' or self.code[node.open.start - 1] == '\n')) {
                    self.has_prev_space = true;
                }
            }

            if (node.kind != .text) { 
                if (!self.has_prev_space) {
                    const name = node.open.getName(self.code, .html).slice(self.code);
                    if (std.ascii.eqlIgnoreCase("br", name)) {
                        self.has_prev_space = true;
                    } else if (std.ascii.eqlIgnoreCase("p", name)) {
                        self.has_prev_space = true;
                    }
                }

                continue; 
            }

            self.next_index = index + 1;
            return node;
        }

        return null;
    }

    pub fn has_space(self: @This()) bool {
        return self.has_prev_space;
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
        if (parent_index == 0) {
            return false;
        }

        if (selector.len == 1 and selector[0] == '>') {
            if (iter.next()) |selector_parent| {
                const current = ast.nodes[parent_index];
                parent_index = current.parent_idx;

                const is_class = selector_parent[0] == '.';
                if (is_class and has_class(current, code, selector_parent)) {
                    continue;
                } else if (std.ascii.eqlIgnoreCase(selector_parent, current.open.getName(code, .html).slice(code))) {
                    continue;
                }
            }
            return false;
        }

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
    }
    return true;
}

pub const HtmlOptions = struct {
    selector_container: []const u8,
    selector_link: ?[]const u8 = null,
    selector_heading: ?[]const u8 = null,
    selector_date: ?[]const u8 = null,
    date_format: ?[]const u8 = null,
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
            const trimmed = mem.trim(u8, val, &std.ascii.whitespace);
            if (trimmed.len == 0) {
                continue;
            }
            return trimmed;
        }
        return null;
    }
};

pub fn is_single_selector_match(content: []const u8, node: super.html.Ast.Node, selector: []const u8) bool {
    const trimmed = mem.trim(u8, selector, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return false;
    }

    if (mem.indexOfScalar(u8, trimmed, ' ') == null) {
        return has_class(node, content, trimmed) or mem.eql(u8, node.open.getName(content, .html).slice(content), trimmed);
    }
    return false;
}

pub fn parse_html(self: *@This(), allocator: Allocator, html_options: HtmlOptions) !ParsedFeed {
    const content = self.doc.data;
    const ast = try super.html.Ast.init(allocator, content, .html);
    if (ast.errors.len > 0) {
        std.log.warn("Html contains {d} parsing error(s). Will try to find feed item anyway.", .{ast.errors.len});
        // ast.printErrors(code, "<STRING>");
    }

    var feed: Feed.Parsed = .{};
    const root_node = ast.nodes[0];
    // ast.debug(content);

    var title_iter = NodeIterator.init(ast, content, root_node, "title");
    if (title_iter.next()) |n| {
        feed.title = try text_location_from_node(ast, content, n);
    }

    var container_iter = NodeIterator.init(ast, content, ast.nodes[0], html_options.selector_container);

    while (container_iter.next()) |node_container| {
        var item_link: ?feed_types.Location = null;
        var item_title: ?feed_types.Location = null;
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
                        item_link = .{ .offset = value.span.start, .len = value.span.end - value.span.start };
                    }
                }
            }

            item_title = try text_location_from_node(ast, content, n);
        }

        if (html_options.selector_heading) |heading| {
            if (is_single_selector_match(content, node, heading)) {
                item_title = try text_location_from_node(ast, content, node);
            } else {
                var heading_iter = NodeIterator.init(ast, content, node, heading);
                if (heading_iter.next()) |node_match| {
                    item_title = try text_location_from_node(ast, content, node_match);
                } else {
                    std.log.warn("Could not find heading node with selector '{s}'", .{heading});
                }
            }
        }

        if (item_title == null) {
            for (&[_][]const u8{"h1", "h2", "h3", "h4", "h5", "h6"}) |tag| {
                if (is_single_selector_match(content, node, tag)) {
                    item_title = try text_location_from_node(ast, content, node);
                    break;
                }

                var heading_iter = NodeIterator.init(ast, content, node, tag);
                if (heading_iter.next()) |node_match| {
                    item_title = try text_location_from_node(ast, content, node_match);
                    break;
                }
            }
        }

        // Find any text inside node
        if (item_title == null) {
            item_title = try text_location_from_node(ast, content, node);
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
            var is_time_datetime = false;

            if (std.ascii.eqlIgnoreCase("time", n.open.slice(content))) {
                var attr_iter = n.startTagIterator(content, .html);
                while (attr_iter.next(content)) |attr| {
                    if (attr.value) |value| {
                        const name = attr.name.slice(content);
                        if (std.ascii.eqlIgnoreCase("datetime", name)) {
                            value_raw = value.span.slice(content);
                            is_time_datetime = true;
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
                const trimmed = mem.trim(u8, raw, &std.ascii.whitespace);
                if (html_options.date_format) |date_format| {
                    item_updated_ts = seconds_from_date_format(trimmed, date_format);
                }

                if (item_updated_ts == null and is_time_datetime) {
                    item_updated_ts = seconds_from_datetime(trimmed);
                }

                // TODO: try some other date parsing formats?
            }
        }

        self.items.appendAssumeCapacity(.{
            .title = item_title,
            .link = item_link,
            .updated_timestamp = item_updated_ts,
        });

        if (self.items.len == default_item_count) {
            break;
        }
    }

    return .{
        .feed = feed,
        .items = self.items.slice(),
    };
}

// ddd MMMM DD YYYY HH:mm:ss GMT+0000 <some long string>
// Example: Sun Feb 19 2023 00:00:00 GMT+0000 (Coordinated Universal Time)
// Used in https://aralroca.com/ feed
pub fn parse_wrong_rss_date(raw: []const u8) ?i64 {
    return seconds_from_date_format(raw, "xxx MMM DD YYYY HH:mm:ss GMTZZZZZ");
}

pub fn seconds_from_date_format(raw: []const u8, date_format: []const u8) ?i64 {
    assert(raw.len > 0);
    assert(date_format.len > 0);
    assert(raw[0] != ' ' and raw[raw.len - 1] != ' ');

    const year_fmt, const year_start = blk: { 
        const year_long_fmt = "YYYY";
        if (mem.indexOf(u8, date_format, year_long_fmt)) |index| {
            break :blk .{year_long_fmt, index};
        }

        const year_short_fmt = "YY";
        break :blk .{year_short_fmt, mem.indexOf(u8, date_format, year_short_fmt)};
    };

    var year: u32 = 0;
    if (year_start) |index| {
        const end = index + year_fmt.len;
        if (end <= raw.len) {
            const year_raw = raw[index..end];
            if (std.fmt.parseUnsigned(u32, year_raw, 10)) |value| {
                // TODO: might have two digit value in 1900s?
                const short_add: u32 = if (value < 100) 2000 else 0;
                year = value + short_add;
            } else |_| {
                std.log.warn("Failed to parse year from '{s}'. Try to parse years value from '{s}'", .{raw, year_raw});
                return null;
            }
        }
    }

    if (year == 0) {
        return null;
    }

    const month_fmt, const month_start = blk: {
        const month_text_fmt = "MMM";
        if (mem.indexOf(u8, date_format, month_text_fmt)) |index| {
            break :blk .{month_text_fmt, index};
        }

        const month_fmt = "MM";
        break :blk .{month_fmt, mem.indexOf(u8, date_format, month_fmt)};
    };
    const month = blk: {
        const index = month_start orelse break :blk 1;
        const end = index + month_fmt.len;
        if (end <= raw.len) {
            const month_raw = raw[index..end];
            if (month_fmt.len == 2) {
                if (std.fmt.parseUnsigned(u32, month_raw, 10)) |value| {
                    break :blk value;
                } else |_| {
                    std.log.warn("Failed to parse month from '{s}'. Try to parse months value from '{s}'", .{raw, month_raw});
                }
            } else if (month_fmt.len == 3) {
                if (datetime.Month.parseAbbr(month_raw)) |value| {
                    break :blk @intFromEnum(value);
                } else |_| {
                    std.log.warn("Failed to parse month from '{s}'. Try to parse months abbreviated value from '{s}'", .{raw, month_raw});
                }
            } else {
                unreachable;
            }
        }

        break :blk 1;
    };
    
    const day_fmt = "DD";
    const day_start = mem.indexOf(u8, date_format, day_fmt);
    var day: u32 = 1;
    if (day_start) |index| {
        const end = index + day_fmt.len;
        if (end <= raw.len) {
            const day_raw = raw[index..end];
            if (std.fmt.parseUnsigned(u32, day_raw, 10)) |value| {
                day = value;
            } else |_| {
                std.log.warn("Failed to parse date from '{s}'. Try to parse days value from '{s}'", .{raw, day_raw});
            }
        }
    }

    const hour_fmt = "HH";
    const hour_start = mem.indexOf(u8, date_format, hour_fmt);
    var hour: u32 = 0;
    if (hour_start) |index| {
        const end = index + hour_fmt.len;
        if (end <= raw.len) {
            const hour_raw = raw[index..end];
            if (std.fmt.parseUnsigned(u32, hour_raw, 10)) |value| {
                hour = value;
            } else |_| {
                std.log.warn("Failed to parse date from '{s}'. Try to parse hour value from '{s}'", .{raw, hour_raw});
            }
        }
    }

    const minute_fmt = "mm";
    const minute_start = mem.indexOf(u8, date_format, minute_fmt);
    var minute: u32 = 0;
    if (minute_start) |index| {
        const end = index + minute_fmt.len;
        if (end <= raw.len) {
            const minute_raw = raw[index..end];
            if (std.fmt.parseUnsigned(u32, minute_raw, 10)) |value| {
                minute = value;
            } else |_| {
                std.log.warn("Failed to parse date from '{s}'. Try to parse minutes value from '{s}'", .{raw, minute_raw});
            }
        }
    }

    const second_fmt = "ss";
    const second_start = mem.indexOf(u8, date_format, second_fmt);
    var second: u32 = 0;
    if (second_start) |index| {
        const end = index + second_fmt.len;
        if (end <= raw.len) {
            const second_raw = raw[index..end];
            if (std.fmt.parseUnsigned(u32, second_raw, 10)) |value| {
                second = value;
            } else |_| {
                std.log.warn("Failed to parse date from '{s}'. Try to parse seconds value from '{s}'", .{raw, second_raw});
            }
        }
    }

    const timezone_fmt = "Z";
    const timezone_start = mem.indexOf(u8, date_format, timezone_fmt);
    var timezone: ?*const dt.datetime.Timezone = null;
    if (timezone_start) |index| blk: {
        var end = index;
        var sign: i8 = 1;
        if (raw[index] == '-') {
            sign = -1;
        } else if (raw[index] != '+') {
            std.log.warn("Try to parse timezone value in date '{s}'", .{raw});
            break :blk;
        }
        end += 1;

        if (end + 2 > raw.len) { break :blk; }
        const hours_raw = raw[end..end + 2];
        var hours: u32 = 0;
        if (std.fmt.parseUnsigned(u32, hours_raw, 10)) |value| {
            hours = value;
        } else |_| {
            std.log.warn("Failed to parse date from '{s}'. Try to parse timezone's hours value from '{s}'", .{raw, hours_raw});
            break :blk;
        }
        end += 2;
        end += @intFromBool(raw[end] == ':');

        if (end + 2 > raw.len) { break :blk; }
        const minutes_raw = raw[end..end + 2];
        var minutes: u32 = 0;
        if (std.fmt.parseUnsigned(u32, minutes_raw, 10)) |value| {
            minutes = value;
        } else |_| {
            std.log.warn("Failed to parse date from '{s}'. Try to parse timezone's minutes value from '{s}'", .{raw, minutes_raw});
            break :blk;
        }

        end += 2;
        const all_minutes: i16 = @intCast(hours * 60 + minutes);
        const offset = sign * all_minutes;

        timezone = &dt.datetime.Timezone.create(raw[index..end], offset);
    }

    const date = datetime.Datetime.create(year, month, day, hour, minute, second, 0, timezone) catch return null;
    return @intFromFloat(date.toSeconds());
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

    var item_datetime: datetime.Datetime = .{
        .date = date.?,
        .time = .{},
        .zone = &datetime.timezones.Zulu,
    };

    const rest = mem.trimLeft(u8, raw[iso_len..], " T");
    const time_end = mem.indexOfAny(u8, rest, ".+-Z") orelse rest.len;
    const time_raw = rest[0..time_end];

    var timezone: ?datetime.Timezone = null;
    if (time_raw.len > 0) {
        var time_iter = mem.splitScalar(u8, time_raw, ':');
        var has_time = false;
        if (time_iter.next()) |hours_str| {
            if (std.fmt.parseUnsigned(u8, hours_str, 10)) |hour| {
                item_datetime.time.hour = hour;
            } else |_| {
                std.log.warn("Failed to parse hours from input '{s}'", .{raw});
            }
        }

        if (time_iter.next()) |minutes_str| {
            if (std.fmt.parseUnsigned(u8, minutes_str, 10)) |minute| {
                item_datetime.time.minute = minute;
            } else |_| {
                std.log.warn("Failed to parse minutes from input '{s}'", .{raw});
            }
            has_time = true;
        }

        if (time_iter.next()) |seconds_str| {
            if (std.fmt.parseUnsigned(u8, seconds_str, 10)) |second| {
                item_datetime.time.second = second;
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
        item_datetime.zone = &zone;
    }

    return @intCast(@divFloor(item_datetime.toTimestamp(), 1000));
}

pub const ContentType = feed_types.ContentType;

pub fn getContentType(content: []const u8) ?ContentType {
    var buf: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buf);
    var doc = zig_xml.StaticDocument.init(content);
    var r = doc.reader(fixed.allocator(), .{});
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
    _ = alloc; // autofix

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

const ParseOptions = struct {
    feed_id: ?u64 = null,
    feed_url: []const u8,
    feed_to_update: ?feed_types.FeedToUpdate = null,
    latest_updated_timestamp: ?i64 = null,
};

pub fn parse(self: *@This(), allocator: Allocator, html_options: ?HtmlOptions, opts: ParseOptions) !ValidFeed {
    assert(util.is_url(opts.feed_url));

    // TODO?: where to allocate and decode string fields?
    // remove allocations from parse* functions, if possible

    const parsed = switch (self.content_type) {
        .atom => try self.parseAtom(),
        .rss => try self.parseRss(),
        .html => if (html_options) |h_opts| try self.parse_html(allocator, h_opts) else {
            std.log.err("Failed to parse html because there are no html options.", .{});
            return error.NoHtmlOptions;
        },
        .xml => return error.NotAtomOrRss,
    };
    var result: ValidFeed = .{
        .feed = .{ .feed_url = opts.feed_url },
    };

    if (opts.feed_id) |feed_id| {
        result.feed.feed_id = feed_id;
    }

    if (self.content_type == .html) {
        assert(html_options != null);
        result.html_opts = html_options;
        result.feed.page_url = result.feed.feed_url;
    }

    const base = try Uri.parse(result.feed.feed_url);

    var buf_arr: [2 * 1024]u8 = undefined;

    if (parsed.feed.title) |loc| {
        // TODO?: maybe overwrite/trash existing location?
        result.feed.title = try text_truncate_alloc(allocator, self.slice_from_loc(loc));
    }

    if (parsed.feed.page_url) |loc| {
        const page_url = self.slice_from_loc(loc);
        if (is_relative_path(page_url)) {
            var buf: []u8 = &buf_arr;
            const page_url_decoded = std.Uri.percentDecodeBackwards(buf, page_url);
            buf = buf[page_url_decoded.len..];
            const page_url_new = try Uri.resolve_inplace(base, page_url_decoded, &buf);
            result.feed.page_url = try std.fmt.allocPrint(allocator, "{}", .{page_url_new});
        }
    }

    if (result.items.len > 0 and result.items[0].updated_timestamp != null) {
        // make feed date newest item date
        result.feed.updated_timestamp = result.items[0].updated_timestamp;
    } else {
        result.feed.updated_timestamp = std.time.timestamp();
    }
    
    sortItems(parsed.items);

    if (parsed.items.len > 1) {
        const ts = if (opts.feed_to_update) |f| f.latest_updated_timestamp else null;
        result.item_interval = get_item_interval(parsed.items, ts);
    }

    var feed_items: std.ArrayListUnmanaged(FeedItem) = try .initCapacity(allocator, parsed.items.len);
    errdefer feed_items.deinit(allocator);

    const timestamp_max = opts.latest_updated_timestamp orelse 0;
    outer: for (parsed.items) |item| {
        if (item.updated_timestamp) |ts| if (ts <= timestamp_max) {
            break :outer;
        };

        var new_item: FeedItem = .{
            .title = "",
            .feed_id = result.feed.feed_id,
            .updated_timestamp = item.updated_timestamp,
        };

        if (item.id) |loc| {
            const item_id = self.slice_from_loc(loc);
            if (opts.feed_to_update) |f| if (mem.eql(u8, item_id, f.latest_item_id orelse "")) {
                break :outer;
            };

            new_item.id = item_id;
        }

        if (item.link) |link_loc| {
            const link = self.slice_from_loc(link_loc);
            if (is_relative_path(link)) {
                var buf: []u8 = &buf_arr;
                const link_decoded = std.Uri.percentDecodeBackwards(buf, link);
                buf = buf[link_decoded.len..];
                const link_new = try Uri.resolve_inplace(base, link_decoded, &buf);
                const new_link = try std.fmt.allocPrint(allocator, "{}", .{link_new});

                if (opts.feed_to_update) |f| if (mem.eql(u8, new_link, f.latest_item_link orelse "")) {
                    break :outer;
                };

                // Don't add feed items with duplicate links
                for (feed_items.items) |feed_item| {
                    if (mem.eql(u8, feed_item.link.?, new_link)) {
                        continue :outer;
                    }
                }

                new_item.link = new_link;
            }
        }

        if (item.title) |loc| {
            new_item.title = try text_truncate_alloc(allocator, self.slice_from_loc(loc));
        }

        feed_items.appendAssumeCapacity(new_item);
    }

    result.items = feed_items.items;
    
    return result;
}

pub fn get_item_interval(items: []FeedItem.Parsed, timestamp_max: ?i64) i64 {
    const ft = feed_types;
    var result: i64 = ft.seconds_in_10_days;
    if (items.len == 0) {
        return result;
    }
    
    const first: i64 = items[0].updated_timestamp orelse return result;
    var second_opt: ?i64 = timestamp_max;
    for (items[1..]) |item| {
        second_opt = item.updated_timestamp orelse continue;
        if (first != second_opt) {
            break;
        }
    }

    // Incase null use default value: seconds_in_10_days
    var second = second_opt orelse return result;

    if (first == second) if (timestamp_max) |ts_max| {
        second = ts_max;
    };

    const now = std.time.timestamp();
    const diff_now = now - first;
    const diff_ab = first - second;
    const diff_min = @min(diff_now, diff_ab);

    if (diff_min >= 0) {
        if (diff_min < ft.seconds_in_6_hours) {
            result = ft.seconds_in_3_hours;
        } else if (diff_min < ft.seconds_in_12_hours) {
            result = ft.seconds_in_6_hours;
        } else if (diff_min < ft.seconds_in_1_day) {
            result = ft.seconds_in_12_hours;
        } else if (diff_min < ft.seconds_in_2_days) {
            result = ft.seconds_in_1_day;
        } else if (diff_min < ft.seconds_in_7_days) {
            result = ft.seconds_in_3_days;
        } else if (diff_min < ft.seconds_in_30_days) {
            result = ft.seconds_in_5_days;
        }
    }

    return result;
}

fn is_relative_path(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '.') {
        return true;
    }

    return false;
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

pub fn tmp_test() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();

    const content = @embedFile("tmp_file");
    var parser: @This() = try .init(arena.allocator(), content);
    defer parser.deinit(arena.allocator());
    const html_opts: HtmlOptions = .{
        .selector_container = ".FrontList",
        // .date_format = "YYYY-MM-DDTHH:mm:ssZ",
    };
    const result = try parser.parse(arena.allocator(), html_opts, .{
        .feed_url = "http://reddit.com",
    });
    // print("slice: |{s}|\n", .{parser.text_arr.items});

    // Wanted output. Line breaks are spaces
    // Had a ton of fun speaking and 
    // watching https://fitc.ca/event/webu24_inperson/ #WebUnleashed 
    // today—thank you for having me! I’ll post my slides when 
    // I get some time!

    for (result.items[0..]) |item| {
        print("|{s}|\n", .{item.title});
    }
}

pub fn main() !void {
    try tmp_test();
}
