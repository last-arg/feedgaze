const feed_types = @import("./feed_types.zig");
const ContentType = feed_types.ContentType;
const std = @import("std");
const print = std.debug.print;
const mem = std.mem;
const Allocator = mem.Allocator;

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

pub fn parse_html(allocator: Allocator, input: []const u8) !HtmlParsed {
    var result: HtmlParsed = .{};
    var feed_arr = FeedLinkArray.init(allocator);
    var content = input;
    while (std.mem.indexOfScalar(u8, content, '<')) |start_index| {
        content = content[start_index + 1 ..];
        if (content[0] == '/') {
            continue;
        }
        const is_a = isValidTag(content, "a");
        const is_link = isValidTag(content, "link");
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
        var end_index = std.mem.indexOfScalar(u8, content, '>') orelse break;
        if (is_link and content[end_index - 1] == '/') {
            end_index -= 1;
        }
        const new_start: usize = if (is_a) 2 else 5;
        var attrs_raw = content[new_start..end_index];
        content = content[end_index..];

        var rel: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var link: ?[]const u8 = null;
        var link_type: ?[]const u8 = null;

        while (mem.indexOfScalar(u8, attrs_raw, '=')) |eql_index| {
            const name = std.mem.trimLeft(u8, attrs_raw[0..eql_index], &std.ascii.whitespace);
            attrs_raw = attrs_raw[eql_index + 1 ..];
            var sep: u8 = ' ';
            const first = attrs_raw[0];
            if (first == '\'' or first == '"') {
                sep = first;
                attrs_raw = attrs_raw[1..];
            }
            const attr_end = mem.indexOfScalar(u8, attrs_raw, sep) orelse attrs_raw.len;
            const value = attrs_raw[0..attr_end];
            if (attr_end != attrs_raw.len) {
                attrs_raw = attrs_raw[attr_end + 1 ..];
            }

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

        const rel_value = rel orelse continue;
        const link_value = link orelse continue;

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
    }

    result.links = feed_arr.items;
    return result;
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
pub fn html_fragemnt_parse() !void {
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
