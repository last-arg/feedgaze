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

pub fn attr_to_icon(raw: []const u8) ?LinkIcon {
    var rel: ?[]const u8 = null; 
    var href: ?[]const u8 = null;
    var sizes: ?[]const u8 = null;

    const trim_values = .{'\'', '"'} ++ std.ascii.whitespace;
    var content = mem.trim(u8, raw, &(.{'/'} ++ std.ascii.whitespace));
    while (content.len > 0) {
        content = skip_whitespace(content);
        if (std.ascii.startsWithIgnoreCase(content, "rel")) {
            content = content[3..];
            if (mem.indexOfScalar(u8, content, '=')) |eql_index| {
                const start = eql_index + 1;
                if (start > content.len) { return null; }
                content = content[start..];
                const end_index = mem.indexOfAny(u8, content, &std.ascii.whitespace) orelse content.len;
                const value = content[0..end_index];
                rel = mem.trim(u8, value, &trim_values);
                content = content[end_index..];
            }
        } else if (std.ascii.startsWithIgnoreCase(content, "href")) {
            content = content[4..];
            if (mem.indexOfScalar(u8, content, '=')) |eql_index| {
                const start = eql_index + 1;
                if (start > content.len) { return null; }
                content = content[start..];
                const end_index = mem.indexOfAny(u8, content, &std.ascii.whitespace) orelse content.len;
                const value = content[0..end_index];
                href = mem.trim(u8, value, &trim_values);
                content = content[end_index..];
            }
        } else if (std.ascii.startsWithIgnoreCase(content, "sizes")) {
            content = content[5..];
            if (mem.indexOfScalar(u8, content, '=')) |eql_index| {
                const start = eql_index + 1;
                if (start > content.len) { return null; }
                content = content[start..];
                const end_index = mem.indexOfAny(u8, content, &std.ascii.whitespace) orelse content.len;
                const value = content[0..end_index];
                sizes = mem.trim(u8, value, &trim_values);
                content = content[end_index..];
            }
        } else {
            var index_end = mem.indexOfAny(u8, content, &std.ascii.whitespace) orelse break;
            const index_equal = mem.indexOf(u8, content, "=") orelse break;
            if (index_equal < index_end) {
                const index_next = index_equal + 1;
                if (index_next >= content.len) {
                    break;
                }
                const sym = content[index_next];
                if (sym == '"' or sym == '\'') {
                    if (mem.indexOf(u8, content, &.{sym})) |index_quote| {
                        const index_next_1 = index_quote + 1;
                        if (index_next_1 < content.len) {
                            index_end = index_next_1;
                        }
                    }
                }
            }
            content = content[index_end..];
        }
    }

    if (rel != null and is_favicon(rel.?)
        and href != null and href.?.len > 0
    ) {
        var result: LinkIcon = .{
            .href = href.?,
        };
        if (sizes) |value| blk: {
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

pub fn parse_html(allocator: Allocator, input: []const u8) !HtmlParsed {
    var result: HtmlParsed = .{};
    var feed_arr = FeedLinkArray.init(allocator);
    var content = input;
    const a_tag = "a";
    const link_tag = "link";
    while (std.mem.indexOfScalar(u8, content, '<')) |start_index| {
        content = content[start_index + 1 ..];
        // skip closing tag
        if (content[0] == '/') {
            const end_index = std.mem.indexOfScalar(u8, content, '>') orelse break;
            content = content[end_index..];
            continue;
        }
        const is_a = isValidTag(content, a_tag);
        const is_link = isValidTag(content, link_tag);
        if (!is_a and !is_link) {
            if (std.mem.startsWith(u8, content, "!--")) {
                // Is a comment. Skip comment.
                content = content[4..];
                if (std.mem.indexOf(u8, content, "-->")) |end| {
                    content = content[end + 1 ..];
                }
            }
            continue;
        }

        const index = if (is_a) a_tag.len else link_tag.len;
        content = content[index..];
        content = skip_whitespace(content);
        content = content[tag_end_index(content)..];

        var rel: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var link: ?[]const u8 = null;
        var link_type: ?[]const u8 = null;


        while (mem.indexOfAny(u8, content, "= >")) |attr_index| {
            const token = content[attr_index];
            if (token == '>') {
                content = content[attr_index..];
                break;
            } else if (token == ' ') {
                // not looking for attribute 'flags' (no value)
                content = skip_whitespace(content[attr_index + 1..]);
                continue;
            }
            const name = content[0..attr_index];
            content = content[attr_index+1..];
            const value = blk: {
                const first = content[0];
                if (first == '"' or first == '\'') {
                    content = content[1..];
                    if (mem.indexOfScalar(u8, content, first)) |value_index| {
                       const value = content[0..value_index];
                       content = content[value_index + 1 ..];
                       break :blk value;
                    }
                } else {
                    if (mem.indexOfAny(u8, content, " >")) |value_index| {
                       const value = content[0..value_index];
                       content = content[value_index ..];
                       break :blk value;
                    }
                }
                @panic("Parsing html attribute failed. Failed to find end of attribute value.");
            };

            if (std.ascii.eqlIgnoreCase(name, "type")) {
                link_type = value;
            } else if (std.ascii.eqlIgnoreCase(name, "rel")) {
                rel = value;
            } else if (std.ascii.eqlIgnoreCase(name, "href")) {
                link = value;
            } else if (std.ascii.eqlIgnoreCase(name, "title")) {
                title = value;
            }
        }

        if (rel) |rel_value| if (link) |link_value| {
            if (link_type != null and
                std.ascii.eqlIgnoreCase(rel_value, "alternate") and !isDuplicate(feed_arr.items, link_value)) {
                if (ContentType.fromString(link_type.?)) |valid_type| {
                    try feed_arr.append(.{
                        .title = if (title) |t| try allocator.dupe(u8, t) else null,
                        .link = try allocator.dupe(u8, link_value),
                        .type = valid_type,
                    });
                }
            }

            // Find first favicon
            if (is_favicon(rel_value) and result.icon_url == null) {
                result.icon_url = link_value;
            }
        };
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
    var iter = mem.splitScalar(u8, rel, ' ');
    while (iter.next()) |val| {
        if (std.ascii.eqlIgnoreCase(val, "icon")) {
            return true;
        }
    }
    return false;
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
