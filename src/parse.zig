const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const ascii = std.ascii;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const l = std.log;

// TODO: decode html entities

pub const Page = struct {
    title: ?[]const u8 = null,
    links: []Link,
};

pub const Link = struct {
    href: []const u8,
    media_type: MediaType = .unknown,
    title: ?[]const u8 = null,
};

pub const MediaType = enum {
    atom,
    rss,
    unknown,
};

pub fn mediaTypeToString(mt: MediaType) []const u8 {
    var name = @tagName(mt);
    return name;
}

const Tag = enum {
    none,
    title,
    link_or_a,
};

pub fn findFeedLinks(allocator: *Allocator, contents_const: []const u8) !Page {
    var contents = contents_const;
    var links = ArrayList(Link).init(allocator);
    defer links.deinit();

    var page_title: ?[]const u8 = null;

    const title_elem = "<title>";
    if (ascii.indexOfIgnoreCase(contents, title_elem)) |index| {
        const start = index + title_elem.len;
        if (ascii.indexOfIgnoreCase(contents[start..], "</title>")) |end| {
            page_title = contents[start .. start + end];
        }
    }

    var link_rel: ?[]const u8 = null;
    var link_type: ?[]const u8 = null;
    var link_title: ?[]const u8 = null;
    var link_href: ?[]const u8 = null;

    const link_elem = "<link ";

    while (ascii.indexOfIgnoreCase(contents[0..], link_elem)) |index| {
        var key: []const u8 = "";
        var value: []const u8 = "";
        contents = contents[index + link_elem.len ..];
        while (true) {
            // skip whitespace
            contents = mem.trimLeft(u8, contents, &ascii.spaces);
            if (contents[0] == '>') {
                contents = contents[1..];
                break;
            } else if (contents[0] == '/') {
                contents = mem.trimLeft(u8, contents[1..], &ascii.spaces);
                if (contents[0] == '>') {
                    contents = contents[1..];
                    break;
                }
            } else if (contents.len == 0) {
                break;
            }

            const next_eql = mem.indexOfScalar(u8, contents, '=') orelse contents.len;
            const next_space = mem.indexOfAny(u8, contents, &ascii.spaces) orelse contents.len;
            const next_slash = mem.indexOfScalar(u8, contents, '/') orelse contents.len;
            const next_gt = mem.indexOfScalar(u8, contents, '>') orelse contents.len;

            const end = blk: {
                var smallest = next_space;
                if (next_slash < smallest) {
                    smallest = next_slash;
                }
                if (next_gt < smallest) {
                    smallest = next_gt;
                }
                break :blk smallest;
            };

            if (next_eql < end) {
                key = contents[0..next_eql];
                contents = contents[next_eql + 1 ..];
                switch (contents[0]) {
                    '"' => {
                        contents = contents[1..];
                        const value_end = mem.indexOfScalar(u8, contents, '"') orelse break;

                        value = contents[0..value_end];
                        contents = contents[value_end + 1 ..];
                    },
                    '\'' => {
                        contents = contents[1..];
                        const value_end = mem.indexOfScalar(u8, contents, '\'') orelse break;

                        value = contents[0..value_end];
                        contents = contents[value_end + 1 ..];
                    },
                    else => {
                        value = contents[0..end];
                        contents = contents[end + 1 ..];
                    },
                }
            } else {
                contents = contents[end + 1 ..];
                continue;
            }

            if (mem.eql(u8, "rel", key)) {
                link_rel = value;
            } else if (mem.eql(u8, "type", key)) {
                link_type = value;
            } else if (mem.eql(u8, "title", key)) {
                link_title = value;
            } else if (mem.eql(u8, "href", key)) {
                link_href = value;
            }
        }

        if (makeLink(link_rel, link_type, link_href, link_title)) |link| {
            try links.append(link);
        }

        link_rel = null;
        link_type = null;
        link_title = null;
        link_href = null;
    }

    return Page{
        .title = page_title,
        .links = links.toOwnedSlice(),
    };
}

fn makeLink(
    rel: ?[]const u8,
    type_: ?[]const u8,
    href: ?[]const u8,
    title: ?[]const u8,
) ?Link {
    const valid_rel = rel != null and mem.eql(u8, "alternate", rel.?);
    const valid_type = type_ != null;

    if (valid_rel and valid_type) {
        if (href) |link_href| {
            const media_type = blk: {
                if (mem.eql(u8, "application/rss+xml", type_.?)) {
                    break :blk MediaType.rss;
                } else if (mem.eql(u8, "application/atom+xml", type_.?)) {
                    break :blk MediaType.atom;
                }
                break :blk MediaType.unknown;
            };
            return Link{
                .href = link_href,
                .title = title,
                .media_type = media_type,
            };
        }
    }

    return null;
}

test "parse html" {
    l.warn("\n", .{});
    const expect = testing.expect;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    // const html = @embedFile("../test/lobste.rs.html");
    const html = @embedFile("../test/test.html");
    const page = try findFeedLinks(allocator, html);
    l.warn("{}", .{page.links.len});
    for (page.links) |link| {
        l.warn("{s}\n", .{link.title});
        l.warn("{s}\n", .{link.href});
    }
    // expect(4 == page.links.len);
    // expect(MediaType.rss == page.links[0].media_type);
}
