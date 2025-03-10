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
};

pub fn parse_icon(content: []const u8) ?[]const u8 {
    var current_index: usize = 0;
    var current_icon: ?LinkIcon = null;

    while (current_index < content.len) {
        const start_index = mem.indexOfScalarPos(u8, content, current_index, '<') orelse break;
        current_index = start_index + 1;
        if (current_index > content.len) { break; }

        const content_slice = content[current_index..];
        if (skip_comment(content_slice)) |end_index| {
            current_index += end_index;
            continue;
        } else if (std.ascii.startsWithIgnoreCase(content_slice, "link")) {
            current_index += 4;
            if (mem.indexOfScalar(u8, content[current_index..], '>')) |end_index| {
                const attr_start = current_index;
                current_index += end_index + 1;
                const attr_raw = content[attr_start..current_index - 1];
                const new_icon = attr_to_icon(attr_raw) orelse continue;
                if (current_icon == null) {
                    current_icon = new_icon;
                    continue;
                }

                const curr_icon = current_icon.?;
                if (curr_icon.size.has_size() and new_icon.size.has_size()) {
                    const curr_dist = curr_icon.size.dist_from_icon_size();
                    const new_dist = new_icon.size.dist_from_icon_size();

                    if (new_dist <= 0
                        and (new_dist > curr_dist or curr_dist > 0)
                    ) {
                        current_icon = new_icon;
                    } else if (new_dist > 0
                        and curr_dist > 0 
                        and new_dist < curr_dist
                    ) {
                        current_icon = new_icon;
                    }
                } else if (new_icon.size.has_size()) {
                    current_icon = new_icon;
                }

                if (curr_icon.size.width == app_config.icon_size) {
                    break;
                }
            }
            continue;
        } 

        if (mem.indexOfScalar(u8, content[current_index..], '>')) |end_index| {
            current_index += end_index + 1;
        }
    }

    if (current_icon) |icon| {
        return icon.href;
    }

    return null;
}

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

pub fn attr_to_icon(raw: []const u8) ?LinkIcon {
    const link_attr = link_attribute_from_raw(raw);

    const rel = link_attr.rel orelse return null;
    const href = link_attr.href orelse return null;

    if (is_favicon(rel) and href.len > 0) {
        var result: LinkIcon = .{
            .href = href,
        };
        if (link_attr.sizes) |value| blk: {
            const end_index = mem.indexOfAny(u8, value, &std.ascii.whitespace) orelse value.len;
            const v = value[0..end_index];
            if (std.ascii.indexOfIgnoreCase(v, "x")) |sep_index| {
                const width = std.fmt.parseUnsigned(u32, v[0..sep_index], 10) catch {
                    std.log.warn("Failed to parse attribute sizes width value from '{s}'", .{v});
                    break :blk;
                };
                const height = std.fmt.parseUnsigned(u32, v[sep_index + 1..], 10) catch {
                    std.log.warn("Failed to parse attribute sizes height value from '{s}'", .{v});
                    break :blk;
                };
                result.size = .{.width = width, .height = height};
            }
        }
        return result;
    }

    return null;
}

// NOTE: function arguement is raw string of element attributes
// <link [raw attrs]>
pub fn link_attribute_from_raw(raw: []const u8) LinkRaw {
    var result: LinkRaw = .{};

    const trim_values = .{'\'', '"'} ++ std.ascii.whitespace;
    var content = mem.trim(u8, raw, &(.{'/'} ++ std.ascii.whitespace));
    while (content.len > 0) {
        content = skip_whitespace(content);

        const index_whitespace = mem.indexOfAny(u8, content, &std.ascii.whitespace) orelse content.len;
        // Only want attributes with values
        const index_equal = mem.indexOfScalar(u8, content, '=') orelse break;
        if (index_equal < index_whitespace) {
            const attr_raw = content[0..index_equal];
            const index_next = index_equal + 1;
            if (index_next >= content.len) { return result; }
            content = content[index_next..];
            const attr_name = LinkAttribute.from_str(attr_raw) orelse continue;
            content = skip_whitespace(content);
            const end_index = mem.indexOfAny(u8, content, &std.ascii.whitespace) orelse content.len;
            const value = mem.trim(u8, content[0..end_index], &trim_values);
            switch (attr_name) {
                .rel => { result.rel = value; },
                .href => { result.href = value; },
                .@"type" => { result.@"type" = value; },
                .title => { result.title = value; },
                .sizes => { result.sizes = value; },
            }
            content = content[end_index..];
        } else {
            content = content[index_whitespace..];
        }
    }

    return result;
}

// Will return index of '>' end comment
pub fn skip_comment(input: []const u8) ?usize {
    if (mem.startsWith(u8, input, "!--")) {
        if (mem.indexOf(u8, input[3..], "-->")) |index| {
            // '-->'.len
            return index + 3;
        }
    }
    return null;
}

const LinkRaw = struct {
    rel: ?[]const u8 = null,
    type: ?[]const u8 = null,
    href: ?[]const u8 = null,
    title: ?[]const u8 = null,
    sizes: ?[]const u8 = null,

    // pub fn init_raw(attr_str: []const u8) ?@This() {
    //     return null;
    // }
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

pub fn parse_html(allocator: Allocator, input: []const u8) !HtmlParsed {
    var result: HtmlParsed = .{};
    var feed_arr = FeedLinkArray.init(allocator);
    var content = input;

    while (std.mem.indexOfScalar(u8, content, '<')) |start_index| {
        var index_next = start_index + 1;
        if (index_next > content.len) { break; }

        content = content[start_index + 1 ..];

        if (skip_comment(content)) |end_index| {
            index_next = end_index + 1;
            if (index_next > content.len) { break; }
            content = content[end_index..];
            continue;
        }

        const index_tag_name_end = mem.indexOfAny(u8, content, &(.{'>'} ++ std.ascii.whitespace)) orelse break;
        const tag_name = content[0..index_tag_name_end];
        content = content[tag_name.len..];
        content = skip_whitespace(content);

        const index_tag_end = mem.indexOfAny(u8, content, &.{'>'}) orelse break;
        const link_attr = link_attribute_from_raw(content[0..index_tag_end]);

        index_next = index_tag_end + 1;
        if (index_next > content.len) { break; }
        content = content[index_next..];

        const rel_value = link_attr.rel orelse continue;
        const link_value = link_attr.href orelse continue;
        const link_type = link_attr.@"type";

        if (link_type != null and
            attr_contains(rel_value, "alternate") and !isDuplicate(feed_arr.items, link_value)) {
            if (ContentType.fromString(link_type.?)) |valid_type| {
                try feed_arr.append(.{
                    .title = if (link_attr.title) |t| try allocator.dupe(u8, t) else null,
                    .link = try allocator.dupe(u8, link_value),
                    .type = valid_type,
                });
            }
        }

        // TODO: choose icon based on desired size
        if (is_favicon(rel_value) and result.icon_url == null) {
            result.icon_url = link_value;
        }
    }

    result.links = feed_arr.items;
    return result;
}

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
    return attr_contains(rel, "icon");
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
    defer buf_arr.deinit();
    var str = input;
    while (std.mem.indexOfAny(u8, str, encode_chars)) |index| {
        buf_arr.appendSliceAssumeCapacity(str[0..index]);
        const value_decoded = try std.unicode.utf8Decode(&[_]u8{str[index]});
        buf_arr.writer().print("&#{d};", .{value_decoded}) catch unreachable;

        const start_next = index + 1;
        str = str[start_next..];
    }
    buf_arr.appendSliceAssumeCapacity(str);
    return buf_arr.toOwnedSlice();
}
