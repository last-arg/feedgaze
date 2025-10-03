const feed_types = @import("./feed_types.zig");
const ContentType = feed_types.ContentType;
const std = @import("std");
const print = std.debug.print;
const mem = std.mem;
const Allocator = mem.Allocator;
const app_config = @import("app_config.zig");

pub const FeedLink = struct {
    link: []const u8,
    type: ContentType,
    title: ?[]const u8 = null,
};

pub const HtmlParsed = struct {
    icon_url: ?[]const u8 = null,
    links: []FeedLink = &.{},
};

const FeedLinkArray = std.ArrayList(FeedLink);
// Resources:
// https://jackevansevo.github.io/the-struggles-of-building-a-feed-reader.html
// https://kevincox.ca/2022/05/06/rss-feed-best-practices/

// Can start with:
// '<a '
// '<link '
// Example: '<link rel="alternate" type="application/rss+xml" title="Example" href="/rss.xml">'

// Possible file ends:
// '.rss'
// '.atom'
// '.xml'

// Common feed link patterns
// '/rss.xml'
// '/index.xml'
// '/atom.xml'
// '/feed.xml'
// '/feed'
// '/rss'

fn isValidTag(content: []const u8, tag: []const u8) bool {
    const is_tag = std.ascii.startsWithIgnoreCase(content, tag);
    if (!is_tag) {
        return false;
    }

    for (&std.ascii.whitespace) |char| {
        if (content[tag.len] == char) {
            return true;
        }
    }
    return false;
}

const IconSize = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn from_str(raw: []const u8) IconSize {
        var result: IconSize = .{};
        const end_index = mem.indexOfAny(u8, raw, &std.ascii.whitespace) orelse raw.len;
        const v = raw[0..end_index];
        if (std.ascii.indexOfIgnoreCase(v, "x")) |sep_index| {
            const width = std.fmt.parseUnsigned(u32, v[0..sep_index], 10) catch {
                std.log.warn("Failed to parse attribute sizes width value from '{s}'", .{v});
                return result;
            };
            const height = std.fmt.parseUnsigned(u32, v[sep_index + 1..], 10) catch {
                std.log.warn("Failed to parse attribute sizes height value from '{s}'", .{v});
                return result;
            };
            result = .{.width = width, .height = height};
        }
        return result;
    }

    pub fn in_range(self: *const @This()) bool {
        return app_config.icon_size_min < self.width and self.width < app_config.icon_size_max;
    }

    pub fn has_size(self: *const @This()) bool {
        return self.width != 0 and self.height != 0;
    }

    // NOTE: negative result: self.width < app_config.icon_size
    // NOTE: positive result: self.width > app_config.icon_size
    pub fn dist_from_icon_size(self: *const @This()) i32 {
        return @as(i32, @intCast(self.width)) - @as(i32, @intCast(app_config.icon_size));
    }
};

const LinkIcon = struct {
    href: []const u8,
    size: IconSize = .{},

    pub fn from_link_raw(link_raw: LinkRaw) ?LinkIcon {
        const href = link_raw.href orelse return null;
        return .{
            .href = href,
            .size = if (link_raw.sizes) |v| IconSize.from_str(v) else .{},
        };
    }

    pub fn pick_icon(a: ?@This(), b: ?@This()) ?@This() {
        const curr_icon = a orelse return b;
        const new_icon = b orelse return curr_icon;

        if (curr_icon.size.has_size() and new_icon.size.has_size()) {
            const curr_dist = curr_icon.size.dist_from_icon_size();
            const new_dist = new_icon.size.dist_from_icon_size();

            if (new_dist <= 0
                and (new_dist > curr_dist or curr_dist > 0)
            ) {
                return new_icon;
            } else if (new_dist > 0
                and curr_dist > 0 
                and new_dist < curr_dist
            ) {
                return new_icon;
            }
        } else if (new_icon.size.has_size()) {
            return new_icon;
        }

        return curr_icon;
    }
};

const LinkAttribute = enum {
    rel,
    href,
    title,
    sizes,
    @"type",

    pub fn from_str(str: []const u8) ?@This() {
        return std.meta.stringToEnum(@This(), str);
    }
};

const LinkRaw = struct {
    rel: ?[]const u8 = null,
    type: ?[]const u8 = null,
    href: ?[]const u8 = null,
    title: ?[]const u8 = null,
    sizes: ?[]const u8 = null,

    pub fn from_iter(iter: *AttributeIterator) LinkRaw {
        var result: LinkRaw = .{};

        while (iter.next()) |attr| {
            const attr_name = LinkAttribute.from_str(attr.name) orelse continue;
            switch (attr_name) {
                .rel => { result.rel = attr.value; },
                .href => { result.href = attr.value; },
                .@"type" => { result.@"type" = attr.value; },
                .title => { result.title = attr.value; },
                .sizes => { result.sizes = attr.value; },
            }
        }

        return result;
    }
};

fn attr_contains(rel: []const u8, wanted: []const u8) bool {
    var iter = mem.splitScalar(u8, rel, ' ');
    while (iter.next()) |val| {
        if (std.ascii.eqlIgnoreCase(val, wanted)) {
            return true;
        }
    }
    return false;
}

pub fn comment_range_pos(input: []const u8, pos: usize) ?struct{start: usize, end: usize} {
    const start = mem.indexOfPos(u8, input, pos, "<!--") orelse return null;
    const end = mem.indexOfPos(u8, input, start + 4, "-->") orelse return null;
    return .{.start = start, .end = end + 2};
}

pub fn parse_icon(input: []const u8) ?[]const u8 {
    var current_icon: ?LinkIcon = null;

    const tag_link = "<link";
    var index_link_opt: ?usize = std.ascii.indexOfIgnoreCase(input, tag_link) orelse return null;

    var comment_range = comment_range_pos(input, 0);
    var index_curr = index_link_opt.?;

    outer: while (index_link_opt) |index| : (index_link_opt = mem.indexOfPos(u8, input, index_curr, tag_link)) {
        while (comment_range) |range| {
            if (index < range.start) {
                break;
            } else if (range.start < index and index < range.end) {
                index_curr = range.end + 1;
                continue :outer;
            } else if (index > range.end) {
                index_curr = index + 1;
                comment_range = comment_range_pos(input, range.end);
            }
        }

        const index_after_name = index + tag_link.len;
        // Skip <link> if it doesn't have attributes
        if (mem.indexOfScalar(u8, &(.{'/'} ++ std.ascii.whitespace), input[index_after_name]) == null) {
            index_curr = index_after_name;
            continue;
        }

        // Have possible link with attributes
        var iter = AttributeIterator.init(input[index_after_name..]);
        const link_raw = LinkRaw.from_iter(&iter);
        // print("raw: {any}\n", .{link_raw});
        index_curr = index_after_name + iter.pos_curr + 1;

        const rel = link_raw.rel orelse continue;

        if (is_favicon(rel)) {
            current_icon = LinkIcon.pick_icon(current_icon, LinkIcon.from_link_raw(link_raw));
            if (current_icon != null and current_icon.?.size.width == app_config.icon_size) {
                break;
            }
        }
    }

    if (current_icon) |icon| {
        return icon.href;
    }

    return null;
}

pub fn parse_html(allocator: Allocator, input: []const u8) !HtmlParsed {
    var feed_arr: FeedLinkArray = .{};
    defer feed_arr.deinit(allocator);
    var icon: ?LinkIcon = null;
    var result: HtmlParsed = .{};

    var index_link_opt: ?usize = std.ascii.indexOfIgnoreCase(input, "<link") orelse return result;
    const index_end = index_link_opt.? + 5;
    const tag_link = input[index_link_opt.?..index_end];

    var comment_range = comment_range_pos(input, 0);
    var index_curr = index_link_opt.?;

    while (index_link_opt) |index| : (index_link_opt = mem.indexOfPos(u8, input, index_curr, tag_link)) {
        if (comment_range) |range| {
            if (range.start < index and index < range.end) {
                index_curr = range.end + 1;
                continue;
            } else if (index > range.end) {
                index_curr = index;
                comment_range = comment_range_pos(input, range.end);
                continue;
            }
        }

        const index_after_name = index + tag_link.len;
        // Skip <link> if it doesn't have attributes
        if (mem.indexOfScalar(u8, &(.{'/'} ++ std.ascii.whitespace), input[index_after_name]) == null) {
            index_curr = index_after_name;
            continue;
        }

        // Have possible link with attributes
        var iter = AttributeIterator.init(input[index_after_name..]);
        const link_raw = LinkRaw.from_iter(&iter);

        index_curr = index_after_name + iter.pos_curr + 1;

        const rel = link_raw.rel orelse continue;
        const href = link_raw.href orelse continue;

        if (link_raw.@"type" != null and
            attr_contains(rel, "alternate") and !isDuplicate(feed_arr.items, href)) {
            if (ContentType.fromString(link_raw.@"type".?)) |valid_type| {
                try feed_arr.append(allocator, .{
                    .title = link_raw.title,
                    .link = href,
                    .type = valid_type,
                });
            }
        } else if (is_favicon(rel)) {
            icon = LinkIcon.pick_icon(icon, LinkIcon.from_link_raw(link_raw));
        }
    }

    result.links = try feed_arr.toOwnedSlice(allocator);
    if (icon) |val| {
        result.icon_url = val.href;
    }
    return result;
}

const AttributeIterator = struct {
    input: []const u8,
    pos_curr: usize = 0, 

    const NameValue = struct {
        name: []const u8,
        value: []const u8 = "",
    };

    pub fn init(input: []const u8) @This() {
        return .{
            .input = input,
        };
    }

    pub fn next(iter: *@This()) ?NameValue {
        var content = iter.input[iter.pos_curr..];
        content = skip_whitespace(content);
        const start_len = content.len;
        iter.pos_curr += start_len - content.len;

        const next_tag_start = mem.indexOfScalar(u8, content, '<') orelse content.len;
        const end_index = mem.lastIndexOfScalar(u8, content[0..next_tag_start], '>') orelse return null;
        content = content[0..end_index];

        const index_equal = mem.indexOfScalar(u8, content, '=') orelse content.len;
        const index_whitespace = mem.indexOfAny(u8, content, &std.ascii.whitespace) orelse content.len;
        const index_min = @min(index_equal, index_whitespace);

        if (index_min >= content.len) {
            iter.pos_curr += content.len;
            return null;
        }

        if (content[index_min] != '=') {
            iter.pos_curr += index_min;
            return null;
        }
        
        const index_start = index_min + 1;
        if (index_start >= content.len) {
            iter.pos_curr += content.len;
            return null;
        }

        var attr_result: NameValue = .{
            .name = content[0..index_min],
        };
        
        var index_content = index_start;
        const first = content[index_start];
        if (first == '\'' or first == '"') {
            const index_quote = mem.indexOfScalarPos(u8, content, index_start + 1, first) orelse index_whitespace;
            attr_result.value = mem.trim(u8, content[index_start..index_quote], &.{first});

            index_content = index_quote;
            if (content[index_quote] == first) {
                index_content += 1;
            }
        } else {
            index_content = index_whitespace + @intFromBool(index_whitespace < content.len);
            attr_result.value = content[index_start..index_content];
        }

        if (index_content > content.len) {
            iter.pos_curr += content.len;
            return null;
        }
        
        iter.pos_curr += index_content;

        return attr_result;
    }
};

fn tag_end_index(content: []const u8) usize {
    if (content[0] == '>') {
        return 1;
    } else if (content[0] == '/' and content[1] == '>') {
        return 2;
    }
    return 0;
}

fn skip_whitespace(content: []const u8) []const u8 {
    for (content, 0..) |char, i| {
        if (!std.ascii.isWhitespace(char)) {
            return content[i..];
        } 
    }
    return content;
}

fn is_favicon(rel: []const u8) bool {
    return attr_contains(rel, "icon") or attr_contains(rel, "apple-touch-icon");
}

fn isDuplicate(items: []FeedLink, link: []const u8) bool {
    for (items) |item| {
        if (mem.eql(u8, item.link, link)) {
            return true;
        }
    }
    return false;
}

const rem = @import("rem");
pub fn html_fragment_parse() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // This is the text that will be read by the parser.
    // Since the parser accepts Unicode codepoints, the text must be decoded before it can be used.
    const input = 
        \\<h1 id="me" class="first" style=bold>Your text goes here!</h1>  
        \\<p>Hello 
        \\    <span>world</span>  big</p>
    ;
    const decoded_input = &rem.util.utf8DecodeStringComptime(input);

    // Create the DOM in which the parsed Document will be created.
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();

    var context_element = rem.Dom.Element{
        .element_type = .html_div,
        .parent = null,
        .attributes = .{},
        .children = .{},
    };

    // Create the HTML parser.
    var parser = try rem.Parser.initFragment(&dom, &context_element, decoded_input, allocator, .report, false, .no_quirks);
    defer parser.deinit();

    // This causes the parser to read the input and produce a Document.
    try parser.run();

    // `errors` returns the list of parse errors that were encountered while parsing.
    // Since we know that our input was well-formed HTML, we expect there to be 0 parse errors.
    const errors = parser.errors();
    std.debug.assert(errors.len == 0);

    // We can now print the resulting Document to the console.
    const stdout = std.io.getStdOut().writer();
    const document = parser.getDocument();
    try rem.util.printDocument(stdout, document, &dom, allocator);
}

// Very simple way to remove html tags. On rare occurences will also remove
// tags from html text. Will only remove tag if after '<' or '&lt;' comes 
// alphabetic character or slash (/).
pub fn HtmlTextIter() type {
    return struct{
        buffer: []const u8,
        index: usize,
        state: State = .text,
        tag_type: TagType = .normal,

        const TagType = enum {
            normal, 
            encoded,

            pub fn to_string_end(self: @This()) []const u8 {
                return switch (self) {
                    .normal => ">",
                    .encoded => "&gt;",
                };
            }

            pub fn len(self: @This()) usize {
                return self.to_string_end().len;
            }
        };

        const State = enum {
            tag,
            text,
        };
        
        pub fn next(self: *@This()) ?[]const u8 {
            if (self.index >= self.buffer.len) {
                return null;
            }
            while (self.index < self.buffer.len) {
                switch(self.state) {
                    .text => {
                        const start_index = self.index;
                        var end_index = self.buffer.len;

                        if (mem.indexOfPosLinear(u8, self.buffer, self.index, "<")) |index| {
                            end_index = index;
                            self.state = .tag;
                            self.tag_type = .normal;
                        }

                        if (mem.indexOfPosLinear(u8, self.buffer, self.index, "&lt;")) |index| {
                            if (index <= end_index) {
                                end_index = index;
                                self.state = .tag;
                                self.tag_type = .encoded;
                            }
                        }

                        self.index = end_index + (if (self.state == .tag) self.tag_type.len() else 0);

                        if (self.state == .tag) {
                            const letter_after_lt = self.buffer[self.index];
                            if (!std.ascii.isAlphabetic(letter_after_lt) and letter_after_lt != '/') {
                                // treat '<' and '&lt;'  as text
                                end_index = self.index;
                                self.state = .text;
                            }
                        }

                        const result = self.buffer[start_index..end_index];

                        if (result.len > 0) {
                            return result;
                        }
                    },
                    .tag => {
                        const needle = self.tag_type.to_string_end();
                        if (mem.indexOfPosLinear(u8, self.buffer, self.index, needle)) |index| {
                            self.index = index + needle.len;
                            self.state = .text;
                        }
                    },
                }
            }

            return null;
        }
    };
}

pub fn html_text(html: []const u8) HtmlTextIter() {
    return .{ .buffer = html, .index = 0 };
}

const encode_chars = "<>\"'/";

pub fn encode_chars_count(input: []const u8) usize {
    var result: usize = 0;
    var start_index: usize = 0;
    while (std.mem.indexOfAnyPos(u8, input, start_index, encode_chars)) |index| {
        result += 1;
        start_index = index + 1;
    }
    return result;
}

// Caller owns the memory if there is something to encode.
// There will be no allocation if there are no characters to encode. Not 
// good solution if caller wants to free memory. Currently don't indicate 
// any way if returned value is allocated or not. 
pub fn encode(allocator: Allocator, input: []const u8) ![]const u8 {
    const count = encode_chars_count(input);
    if (count == 0) {
        return input;
    }
    const capacity = (input.len - count) + (5 * count);
    var buf_arr = try std.ArrayList(u8).initCapacity(allocator, capacity);
    defer buf_arr.deinit(allocator);
    var str = input;
    while (std.mem.indexOfAny(u8, str, encode_chars)) |index| {
        buf_arr.appendSliceAssumeCapacity(str[0..index]);
        const value_decoded = try std.unicode.utf8Decode(&[_]u8{str[index]});
        buf_arr.writer(allocator).print("&#{d};", .{value_decoded}) catch unreachable;

        const start_next = index + 1;
        str = str[start_next..];
    }
    buf_arr.appendSliceAssumeCapacity(str);
    return buf_arr.toOwnedSlice(allocator);
}
