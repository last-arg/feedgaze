const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const print = std.debug.print;
const assert = std.debug.assert;
const Uri = std.Uri;

const dt = @import("zig-datetime");
const datetime = dt.datetime;
const super = @import("superhtml");

const default_item_count = @import("./app_config.zig").max_items;
const feed_types = @import("./feed_types.zig");
const RssDateTime = feed_types.RssDateTime;
const AtomDateTime = feed_types.AtomDateTime;
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
pub const ContentType = feed_types.ContentType;
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

var buffer: [default_item_count]FeedItem.Parsed = undefined;
const ParsedItems = std.ArrayListUnmanaged(FeedItem.Parsed);
items: ParsedItems = .initBuffer(&buffer),
content: []const u8,

pub fn init(content: []const u8) !@This() {
    return .{
        .content = content,
    };
}

pub fn slice_from_loc(self: *@This(), loc: feed_types.Location) []const u8 {
    return self.content[loc.offset..loc.offset + loc.len];
}

pub const ParsedFeed = struct {
    feed: Feed.Parsed,
    items: []FeedItem.Parsed,
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
    defer arr.deinit(allocator);

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

    return arr.toOwnedSlice(allocator);
}

const WriterContext = struct {
    buf: []u8,
    len: usize,
};

pub fn buf_writer(ctx: *WriterContext) std.io.AnyWriter {
    const w = std.io.AnyWriter{
        .context = ctx,
        .writeFn = struct {
            fn func (context: *const anyopaque, bytes: []const u8) anyerror!usize {
                const c: *WriterContext = @constCast(@alignCast(@ptrCast(context)));
                mem.copyForwards(u8, c.buf[c.len..], bytes);
                c.len += bytes.len;
                return bytes.len;
            }
        }.func,
    };

    return w;
}

// https://html.spec.whatwg.org/multipage/syntax.html#syntax-charref
// Mutates 'input' buffer
// 'lt' and 'gt' are handled by html_unescaped_tags()
pub fn html_unescape(input: []u8) []u8 {
    // &amp; = &#38;
    var out = input;
    inline for (.{"&amp;", "&#38;"}) |ent| {
        const count = mem.replace(u8, out, ent, "&", out);
        const len = out.len - ((ent.len - 1) * count);
        out = out[0..len];
    }

    const entities = [_][]const u8{"amp", "quot", "apos", "nbsp"};
    const raws = [_][]const u8{    "&",   "\"",   "'",    " "};

    var ctx: WriterContext = .{
        .buf = out,
        .len = 0,
    };
    const w = buf_writer(&ctx);

    var buf_index_start: usize = 0;

    while (mem.indexOfScalarPos(u8, out, buf_index_start, '&')) |index| {
        w.writeAll(out[buf_index_start..index]) catch unreachable;
        buf_index_start = index + 1;
        const start = buf_index_start;
        if (start >= out.len) { break; }

        if (out[start] == '#') {
            // numeric entities
            var nr_start = start + 1; 
            const end = mem.indexOfScalarPos(u8, out, nr_start, ';') orelse continue;
            const is_hex = out[nr_start] == 'x' or out[nr_start] == 'X';
            nr_start += @intFromBool(is_hex);
            const value = out[nr_start..end];
            if (value.len == 0) { continue; }
            buf_index_start = end + 1;

            const base: u8 = if (is_hex) 16 else 10;
            const nr = std.fmt.parseUnsigned(u21, value, base) catch continue;
            var buf_cp: [4]u8 = undefined;
            const cp = std.unicode.utf8Encode(nr, &buf_cp) catch continue;
            w.writeAll(buf_cp[0..cp]) catch unreachable;
        } else {
            // named entities
            const index_opt: ?usize = blk: {
                for (entities, 0..) |entity, i| {
                    if (mem.startsWith(u8, out[start..], entity) and
                        start + entity.len < out.len and out[start + entity.len] == ';'
                    ) {
                        break :blk i;
                    }
                }

                break :blk null;
            };

            if (index_opt) |i| {
                buf_index_start += entities[i].len + 1;
                w.writeAll(raws[i]) catch unreachable;
            }
        }
    }

    w.writeAll(out[buf_index_start..]) catch unreachable;
    return out[0..ctx.len];
}

// Modifies 'input' buffer
pub fn html_unescape_tags(input: []u8) []u8 {
    const entities = [_][]const u8{"&lt;", "&gt;", "&#60;", "&#62;" };
    const raws = [_][]const u8{    "<",    ">"   , "<",     ">"  };

    var out = input;
    for (entities, raws) |ent, raw| {
        const count = mem.replace(u8, out, ent, raw, out);
        const len = out.len - ((ent.len - raw.len) * count);
        out = out[0..len];
    }

    return out;
}

fn is_void(input: []const u8) bool {
    const void_tags = .{
        "area",
        "base",
        "basefont",
        "bgsound",
        "br",
        "col",
        "command",
        "embed",
        "frame",
        "hr",
        "image",
        "img",
        "input",
        "isindex",
        "keygen",
        "link",
        "menuitem",
        "meta",
        "nextid",
        "param",
        "source",
        "track",
        "wbr",
    };

    inline for (void_tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag, input)) {
            return true;
        }
    }
    return false;
}

fn ignore_these_errors(errors: []const super.html.Ast.Error, content: []const u8) bool {
    for (errors) |err| {
        switch (err.tag) {
            .ast => |err_enum| {
                if (err_enum != .html_elements_cant_self_close
                    and !is_void(err.main_location.slice(content))
                ) {
                    return false;
                }
            },
            .token => {}
        }
    }

    return true;
}


pub fn text_truncate_alloc(allocator: Allocator, text: []const u8) ![]const u8 {
    var input = mem.trim(u8, text, &std.ascii.whitespace);
    if (input.len == 0) {
        return "";
    }

    var stack_fallback = std.heap.stackFallback(1024, allocator);
    var stack_alloc = stack_fallback.get();
    // NOTE: not freeing
    // - if on stack will be gone
    // - if on heap just return as fn result
    input = try stack_alloc.dupe(u8, input);

    if (mem.indexOfScalar(u8, input, '&') != null and mem.indexOfScalar(u8, input, ';') != null) {
        input = html_unescape_tags(@constCast(input));
    }

    if (mem.indexOfScalar(u8, input, '<') != null) {
        const ast = try super.html.Ast.init(allocator, input, .html, false);
        defer ast.deinit(allocator);
        if (ast.errors.len == 0 or ignore_these_errors(ast.errors, input)) {
            input = try text_from_node(ast, @constCast(input), ast.nodes[0]);
        } else {
            std.log.warn("Possible invalid HTML: '{s}'", .{input});
            for (ast.errors) |err| {
                std.log.err("HTML error from '{s}': {}", .{err.main_location.slice(input), err.tag});
            }
        }
    }

    input = html_unescape(@constCast(input));

    var ctx: WriterContext = .{
        .buf = @constCast(input),
        .len = 0,
    };
    const w = buf_writer(&ctx);

    // Remove extra whitespaces
    var iter = mem.tokenizeAny(u8, input, &std.ascii.whitespace);
    if (iter.next()) |first| {
        w.writeAll(first) catch unreachable;

        while (iter.next()) |chunk| {
            if (ctx.len >= max_title_len) { break; }

            w.writeByte(' ') catch unreachable;
            w.writeAll(chunk) catch unreachable;
        }
    }
        
    input = input[0..@min(ctx.len, max_title_len)];
    if (stack_fallback.fixed_buffer_allocator.ownsPtr(@constCast(input.ptr))) {
        input = try allocator.dupe(u8, input);
    }

    return input;
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

    const Self = @This();

    pub fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

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

fn add_or_replace_item(entries: *ParsedItems, current_item: FeedItem.Parsed) void {
    const items = entries.items;
    if (items.len == entries.capacity) {
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
                    entries.replaceRangeAssumeCapacity(replace_index, 1, &[_]FeedItem.Parsed{current_item});
                }
            } else {
                entries.replaceRangeAssumeCapacity(replace_index, 1, &[_]FeedItem.Parsed{current_item});
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

fn text_from_node(ast: super.html.Ast, input: []u8, node: super.html.Ast.Node) ![]u8 {
    // NOTE: this input might still contains unescaped html entities
    const max_len = max_title_len + 20 + @divFloor(max_title_len, 10); 

    var ctx: WriterContext = .{
        .buf = input,
        .len = 0,
    };
    const w = buf_writer(&ctx);

    var iter_text_node = IteratorTextNode.init(ast, input, node);
    if (iter_text_node.next()) |text_node| {
        const text = text_node.open.slice(input);
        w.writeAll(text) catch unreachable;
    }
    while (iter_text_node.next()) |text_node| {
        if (ctx.len > max_len) {
            break;
        }
        if (iter_text_node.has_space()) {
            w.writeByte(' ') catch unreachable;
        }
        const text = text_node.open.slice(input);
        w.writeAll(text) catch unreachable;
    }

    return input[0..ctx.len];
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
    has_whitespace_tag: bool = false,

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
        self.has_whitespace_tag = false;
        if (self.next_index == 0 or self.next_index >= self.ast.nodes.len) {
            return null;
        }

        for (self.ast.nodes[self.next_index..self.end_index], self.next_index..) |node, index| {
            if (!self.has_whitespace_tag) {
                if (node.open.start > 0 and 
                 (self.code[node.open.start - 1] == ' ' or self.code[node.open.start - 1] == '\n')) {
                    self.has_whitespace_tag = true;
                }
            }

            if (node.kind != .text) { 
                if (!self.has_whitespace_tag) {
                    const name = node.open.getName(self.code, .html).slice(self.code);
                    if (std.ascii.eqlIgnoreCase("br", name)
                        or std.ascii.eqlIgnoreCase("p", name)
                    ) {
                        self.has_whitespace_tag = true;
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
        return self.has_whitespace_tag;
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
    const content = self.content;
    const ast = try super.html.Ast.init(allocator, content, .html, false);
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
            }
        }

        self.items.appendAssumeCapacity(.{
            .title = item_title,
            .link = item_link,
            .updated_timestamp = item_updated_ts,
        });

        if (self.items.items.len == self.items.capacity) {
            break;
        }
    }

    return .{
        .feed = feed,
        .items = self.items.items,
    };
}

// ddd MMMM DD YYYY HH:mm:ss GMT+0000 <some long string>
// Example: Sun Feb 19 2023 00:00:00 GMT+0000 (Coordinated Universal Time)
// Used in https://aralroca.com/ feed
pub fn parse_wrong_rss_date(raw: []const u8) ?i64 {
    return seconds_from_date_format(raw, "xxx MMM DD YYYY HH:mm:ss GMTZZZZZ");
}

const DateValue = struct {
    str: []const u8,
    index: usize,
};

pub fn seconds_from_date_format(raw: []const u8, date_format: []const u8) ?i64 {
    assert(raw.len > 0);
    assert(date_format.len > 0);
    assert(raw[0] != ' ' and raw[raw.len - 1] != ' ');

    var buf: [7]DateValue = undefined;
    var date_fmts = std.ArrayListUnmanaged(DateValue).initBuffer(&buf);

    if (mem.indexOf(u8, date_format, "YYYY")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "YYYY",
            .index = index,
        });
    } else if (mem.indexOf(u8, date_format, "YY")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "YY",
            .index = index,
        });
    }

    if (mem.indexOf(u8, date_format, "MMM")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "MMM",
            .index = index,
        });
    } else if (mem.indexOf(u8, date_format, "MM")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "MM",
            .index = index,
        });
    }

    if (mem.indexOf(u8, date_format, "DD")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "DD",
            .index = index,
        });
    }

    if (mem.indexOf(u8, date_format, "HH")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "HH",
            .index = index,
        });
    }

    if (mem.indexOf(u8, date_format, "mm")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "mm",
            .index = index,
        });
    }

    if (mem.indexOf(u8, date_format, "ss")) |index| {
        date_fmts.appendAssumeCapacity(.{
            .str = "ss",
            .index = index,
        });
    }

    if (mem.indexOf(u8, date_format, "Z")) |index| {
        date_fmts.appendAssumeCapacity(.{ .str = "Z",
            .index = index,
        });
    }

    std.mem.sort(DateValue, date_fmts.items, {}, struct{
        fn less_than(_: void, lhs: DateValue, rhs: DateValue) bool {
            return lhs.index < rhs.index;
        }
    }.less_than);

    // TODO?: should all or some date values default
    // to current datetime?
    var month: u32 = 0;
    var year: u32 = 0;
    var day: u32 = 0;
    var hour: u32 = 0;
    var minute: u32 = 0;
    var second: u32 = 0;
    var timezone: ?dt.datetime.Timezone = null;

    for (date_fmts.items, 0..) |date_fmt, date_i| {
        const fmt_len = date_fmt.str.len;
        const end = @min(date_fmt.index + fmt_len, raw.len);
        const raw_value = raw[date_fmt.index..end];

        const first = raw_value[0];
        if (first >= '0' and first <= '9') {
            var end_number = raw_value.len;
            for (raw_value, 0..) |char, i| {
                if (char < '0' or char > '9') {
                    end_number = i;
                    break;
                }
            }
            if (end_number == 0) {
                std.log.warn("Date value '{s}' does not start with a number", .{raw_value});
                continue;
            } else if (end_number < fmt_len) {
                const diff = fmt_len - end_number;
                for (date_fmts.items[date_i + 1..]) |*date_rest| {
                    date_rest.index -= diff;
                }
            }
            
            const raw_number = raw_value[0..end_number];
            if (std.fmt.parseUnsigned(u32, raw_number, 10)) |value| {
                if (std.mem.eql(u8, "YY", date_fmt.str)) {
                    year = 2000 + value;
                } else if (std.mem.eql(u8, "YYYY", date_fmt.str)) {
                    year = value;
                } else if (std.mem.eql(u8, "MM", date_fmt.str)) {
                    month = value;
                } else if (std.mem.eql(u8, "DD", date_fmt.str)) {
                    day = value;
                } else if (std.mem.eql(u8, "HH", date_fmt.str)) {
                    hour = value;
                } else if (std.mem.eql(u8, "mm", date_fmt.str)) {
                    minute = value;
                } else if (std.mem.eql(u8, "ss", date_fmt.str)) {
                    second = value;
                }
            } else |_| {
                // NOTE: This should not happen.
                std.log.warn("Failed to parse date value '{s}' to number", .{raw_number});
            }
        } else if (std.mem.eql(u8, "MMM", date_fmt.str)) {
            if (datetime.Month.parseAbbr(raw_value)) |value| {
                month = @intFromEnum(value);
            } else |_| {
                std.log.warn("Failed to parse months abbreviated value from '{s}'", .{raw_value});
            }
        } else if (std.mem.eql(u8, "Z", date_fmt.str)) {
            const index = date_fmt.index;
            var end_tz = index;
            var sign: i8 = 1;
            if (raw[index] == '-') {
                sign = -1;
            } else if (raw[index] != '+') {
                std.log.warn("Failed to parse timezone date value from input '{s}'", .{raw});
                continue;
            }
            end_tz += 1;

            if (end_tz + 2 > raw.len) { break; }
            const hours_raw = raw[end_tz..end_tz + 2];
            var hours: u32 = 0;
            if (std.fmt.parseUnsigned(u32, hours_raw, 10)) |value| {
                hours = value;
            } else |_| {
                std.log.warn("Failed to parse timezone's hours value from input '{s}'", .{hours_raw});
                continue;
            }
            end_tz += 2;
            end_tz += @intFromBool(raw[end_tz] == ':');

            if (end_tz + 2 > raw.len) { break; }
            const minutes_raw = raw[end_tz..end_tz + 2];
            var minutes: u32 = 0;
            if (std.fmt.parseUnsigned(u32, minutes_raw, 10)) |value| {
                minutes = value;
            } else |_| {
                std.log.warn("Failed to parse timezone's minutes value from input '{s}'", .{minutes_raw});
                continue;
            }

            end_tz += 2;
            const all_minutes: i16 = @intCast(hours * 60 + minutes);
            const offset = sign * all_minutes;

            timezone = dt.datetime.Timezone.create(raw[index..end_tz], offset, .no_dst);
        } else {
            std.log.warn("Failed to find valid date value for '{s}' from '{s}'", .{date_fmt.str, raw_value});
        }
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
        .zone = datetime.timezones.Zulu,
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

                timezone = datetime.Timezone.create(timezone_name, timezone_offset, .no_dst);
            }
        }
    }

    if (timezone) |zone| {
        item_datetime.zone = zone;
    }

    return @intCast(@divFloor(item_datetime.toTimestamp(), 1000));
}

pub fn getContentType(content: []const u8) ?ContentType {
    var tokenizer: super.html.Tokenizer = .{
        .language = .xml,
    };

    while (tokenizer.next(content)) |token| {
        switch (token) {
            .tag_name,
            .attr => {},
            .doctype => |in| {
                if (in.name) |name| if (std.ascii.eqlIgnoreCase("html", name.slice(content))) {
                    return .html;
                };
            },
            .tag => |in| {
                const name = in.name.slice(content);
                if (mem.eql(u8, "feed", name)) {
                    return .atom;
                } else if (mem.eql(u8, "rss", name)) {
                    return .rss;
                } else if (std.ascii.eqlIgnoreCase("html", name)) {
                    return .html;
                }
            },
            .text,
            .comment,
            .parse_error => {},
        }
    }

    return null;
}

test "getContentType" {
    const rss =
        \\<!-- Comment -->
        \\<?xml version="1.0"?>
        \\<rss version="2.0">
        \\   <channel>
        \\   </channel>
        \\</rss>
    ;
    const rss_type = getContentType(rss);
    try std.testing.expectEqual(ContentType.rss, rss_type.?);

    const atom =
        \\<!-- Comment -->
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\</feed>
    ;
    const atom_type = getContentType(atom);
    try std.testing.expectEqual(ContentType.atom, atom_type.?);

    const html_raw =
        \\<!-- Comment -->
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

    // Server might return wrong content/file type for content. Like: 'https://jakearchibald.com/'
    const ct = getContentType(mem.trim(u8, self.content, &std.ascii.whitespace)) orelse return error.UnknownContentType;

    const parsed = switch (ct) {
        .atom => self.parse_atom(),
        .rss => self.parse_rss(),
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

    if (ct == .html) {
        assert(html_options != null);
        result.html_opts = html_options;
        result.feed.page_url = result.feed.feed_url;
    }

    const base = try Uri.parse(result.feed.feed_url);

    var buf_arr: [2 * 1024]u8 = undefined;

    if (parsed.feed.title) |loc| {
        result.feed.title = try text_truncate_alloc(allocator, self.slice_from_loc(loc));
    }

    if (parsed.feed.page_url) |loc| {
        const page_url = self.slice_from_loc(loc);
        if (is_relative_path(page_url)) {
            var buf: []u8 = &buf_arr;
            const page_url_decoded = std.Uri.percentDecodeBackwards(buf, page_url);
            buf = buf[page_url_decoded.len..];
            const page_url_new = try Uri.resolveInPlace(base, page_url_decoded.len, &buf);
            result.feed.page_url = try std.fmt.allocPrint(allocator, "{f}", .{page_url_new});
        } else {
            result.feed.page_url = page_url;
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
            var link = self.slice_from_loc(link_loc);

            if (is_relative_path(link)) {
                var buf: []u8 = &buf_arr;
                const link_decoded = std.Uri.percentDecodeBackwards(buf, link);
                buf = buf[link_decoded.len..];
                const link_new = try Uri.resolveInPlace(base, link_decoded.len, &buf);
                link = try std.fmt.allocPrint(allocator, "{f}", .{link_new});

            }

            if (opts.feed_to_update) |f| if (mem.eql(u8, link, f.latest_item_link orelse "")) {
                break :outer;
            };

            // Don't add feed items with duplicate links
            for (feed_items.items) |feed_item| {
                if (mem.eql(u8, feed_item.link.?, link)) {
                    continue :outer;
                }
            }

            new_item.link = link;
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
    const now = std.time.timestamp();
    const diff = now - first;
    if (diff > ft.seconds_in_30_days) {
        return result;
    }
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

fn parse_rss(self: *@This()) ParsedFeed {
    const content = self.content;

    var feed: Feed.Parsed = .{};
    var state: RssParseState = .channel;
    var state_item: ?RssParseTag = null;
    var current_item: FeedItem.Parsed = .{};

    var tokenizer: super.html.Tokenizer = .{
        .language = .xml,
    };

    while (tokenizer.next(content)) |token| {
        switch (token) {
            .tag_name,
            .attr => unreachable,
            .doctype => {},
            .tag => |tag| {
                const tag_str = tag.name.slice(content);
                switch (tag.kind) {
                    .start => {
                        state_item = RssParseTag.fromString(tag_str);
                        if (state_item != null) {
                            continue;
                        }

                        if (RssParseState.fromString(tag_str)) |s| {
                            state = s;
                        }
                    },
                    .end => {
                        if (RssParseState.fromString(tag_str)) |new_state| {
                            if (new_state == .item) {
                                add_or_replace_item(&self.items, current_item);
                                current_item = .{};
                            }

                            state = .channel;
                            state_item = null;
                        }
                    },
                    .start_self,
                    .end_self => {},
                }
            },
            .comment => |span| {
                const cdata_str = "<![CDATA[";
                if (!mem.startsWith(u8, span.slice(content), cdata_str)) {
                    continue;
                }

                const offset = span.start + cdata_str.len;
                const loc: feed_types.Location = .{
                    .offset = @intCast(offset),
                    .len = @intCast(span.end - offset - 3),
                };
                parse_rss_current_state(&feed, &current_item, state, state_item, loc, content);
            },
            .text => |span| {
                const loc: feed_types.Location = .{.offset = span.start, .len = span.end - span.start };
                parse_rss_current_state(&feed, &current_item, state, state_item, loc, content);
            },
            .parse_error => |err| {
                std.log.warn("RSS parsing error: {}\nSource: {s}", .{err.tag, err.span.slice(content)});
            },
        }

    }

    return .{ .feed = feed, .items = self.items.items };
}

fn parse_rss_current_state(
    feed: *Feed.Parsed,
    current_item: *FeedItem.Parsed,
    state: RssParseState,
    state_item: ?RssParseTag,
    loc: feed_types.Location,
    content: []const u8,
) void {
    switch (state) {
        .channel => if (state_item) |s| switch (s) {
            .title => {
                feed.title = loc;
            },
            .link => {
                feed.page_url = loc;
            },
            .pubDate, .@"dc:date" => {
                const date_raw = content[loc.offset..loc.offset + loc.len];
                const date_str = mem.trim(u8, date_raw, &std.ascii.whitespace);
                feed.updated_timestamp = RssDateTime.parse(date_str) catch 
                    AtomDateTime.parse(date_str) catch
                    parse_wrong_rss_date(date_str) orelse null;
            },
            .guid, .description => {},

        },
        .item => if (state_item) |s| switch (s) {
            .title => current_item.title = loc,
            .description => {
                if (current_item.title == null) {
                    current_item.title = loc;
                }
            },
            .guid => current_item.id = loc,
            .link => current_item.link = loc,
            .pubDate, .@"dc:date" => {
                const date_raw = content[loc.offset..loc.offset + loc.len];
                const date_str = mem.trim(u8, date_raw, &std.ascii.whitespace);
                current_item.updated_timestamp = RssDateTime.parse(date_str) catch 
                    AtomDateTime.parse(date_str) catch
                    parse_wrong_rss_date(date_str) orelse null;
            },
        },
    }
}

fn parse_atom(self: *@This()) ParsedFeed {
    const content = self.content;

    var feed: Feed.Parsed = .{};
    var state: AtomParseState = .feed;
    var state_item: ?AtomParseTag = null;
    var current_item: FeedItem.Parsed = .{};

    var tokenizer: super.html.Tokenizer = .{
        .language = .xml,
    };

    loop: while (tokenizer.next(content)) |token| {
        switch (token) {
            .tag_name,
            .attr => unreachable,
            .doctype => {},
            .tag => |tag| {
                const tag_str = tag.name.slice(content);
                switch (tag.kind) {
                    .start => {
                        state_item = AtomParseTag.fromString(tag_str);
                        if (state_item) |s| {
                            if (s == .link) {
                                if (parse_atom_link(content, tag.span.start)) |loc_val| {
                                    if (state == .entry) {
                                        current_item.link = loc_val;
                                    } else if (state == .feed) {
                                        feed.page_url = loc_val;
                                    } else unreachable;
                                }
                            }

                            continue :loop;
                        }

                        if (AtomParseState.fromString(tag_str)) |s| {
                            state = s;
                        }
                    },
                    .end => {
                        if (AtomParseState.fromString(tag_str)) |new_state| {
                            if (new_state == .entry) {
                                add_or_replace_item(&self.items, current_item);
                                current_item = .{};
                            }

                            state = .feed;
                            state_item = null;
                        }
                    },
                    .start_self => {
                        state_item = AtomParseTag.fromString(tag_str);
                        if (state_item == .link) {
                            if (parse_atom_link(content, tag.span.start)) |loc_val| {
                                if (state == .entry) {
                                    current_item.link = loc_val;
                                } else if (state == .feed) {
                                    feed.page_url = loc_val;
                                } else unreachable;
                            }
                            state_item = null;
                        }
                    },
                    .end_self => {
                        print("self end\n", .{});
                    },
                }
            },
            .comment => |span| {
                const cdata_str = "<![CDATA[";
                if (!mem.startsWith(u8, span.slice(content), cdata_str)) {
                    continue :loop;
                }

                const offset = span.start + cdata_str.len;
                const loc: feed_types.Location = .{
                    .offset = @intCast(offset),
                    .len = @intCast(span.end - offset - 3),
                };

                if (state_item != .link) {
                    parse_atom_current_state(&feed, &current_item, state, state_item, loc, content);
                }
            },
            .text => |span| {
                const loc: feed_types.Location = .{.offset = span.start, .len = span.len() };
                if (state_item != .link) {
                    parse_atom_current_state(&feed, &current_item, state, state_item, loc, content);
                }
            },
            .parse_error => |err| {
                std.log.warn("Atom parsing error: {}\nSource: {s}", .{err.tag, err.span.slice(content)});
            },
        }

    }

    return .{ .feed = feed, .items = self.items.items };
}

fn parse_atom_current_state(
    feed: *Feed.Parsed,
    current_item: *FeedItem.Parsed,
    state: AtomParseState,
    state_item: ?AtomParseTag,
    loc: feed_types.Location,
    content: []const u8,
) void {
    switch (state) {
        .feed => if (state_item) |s| switch (s) {
            .title => {
                feed.title = loc;
            },
            .link => {},
            .updated => {
                const date_raw = content[loc.offset..loc.offset + loc.len];
                feed.updated_timestamp = AtomDateTime.parse(date_raw) catch null;
            },
            .published, .id => {},
        },
        .entry => if (state_item) |s| switch (s) {
            .title => {
                current_item.title = loc;
            },
            .id => current_item.id = loc,
            .link => {},
            .updated, .published => {
                if (current_item.updated_timestamp != null and s == .updated) {
                    return;
                }

                const date_raw = content[loc.offset..loc.offset + loc.len];
                if (AtomDateTime.parse(date_raw)) |new_date| {
                    current_item.updated_timestamp = new_date;
                } else |err| {
                    std.log.warn("Failed to parse atom date: '{s}'. Error: {}", .{date_raw, err});
                }
            },
        },
    }
}

pub fn parse_atom_link(
    content: []const u8,
    start_index: u32,
) ?feed_types.Location {
    var rel: []const u8 = "alternate";
    var link_span: ?super.Span = null;

    var tt: super.html.Tokenizer = .{
        .language = .xml,
        .idx = start_index,
        .return_attrs = true,
    };

    while (tt.next(content)) |maybe_attr| {
        switch (maybe_attr) {
            else => {
                std.log.warn("found unexpected: '{s}' {any}", .{
                    @tagName(maybe_attr),
                    maybe_attr,
                });
                std.log.warn("text: '{s}'", .{
                    maybe_attr.text.slice(content),

                });
                unreachable;
            },
            .tag_name => {},
            .tag => break,
            .parse_error => {},
            .attr => |attr| {
                const attr_name = attr.name.slice(content);
                if (std.ascii.eqlIgnoreCase(attr_name, "rel")) {
                    if (attr.value) |val| {
                        rel = content[val.span.start..val.span.end];
                    }
                } else if (std.ascii.eqlIgnoreCase(attr_name, "href")) {
                    if (attr.value) |val| {
                        link_span = val.span;
                    }
                }
            },
        }
    }


    if (link_span) |span| if (std.ascii.eqlIgnoreCase(rel, "alternate")) {
        return .{.offset = span.start, .len = span.len()};
    };

    return null;
}

pub fn main() !void {
    _ = seconds_from_date_format("7 2", "MM YY");
}
