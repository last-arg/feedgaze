const std = @import("std");
const xml = @import("xml");
const warn = std.debug.warn;
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const l = std.log;

// How to find Rss links in html:
// https://developer.mozilla.org/en-US/docs/Archive/RSS/Getting_Started/Syndicating
// https://webmasters.stackexchange.com/questions/55130/can-i-use-link-tags-in-the-body-of-an-html-document
//
// TODO: find atom feed
// <link href="atom.xml" type="application/atom+xml" rel="alternate" title="Sitewide Atom feed" />

const Tag = enum {
    none,
    title,
    link_or_a,
};

pub const Page = struct {
    title: ?[]const u8 = null,
    links: []Link,
};

const MediaType = enum {
    atom,
    rss,
    unknown,
};

const Link = struct {
    href: []const u8,
    media_type: MediaType = .unknown,
    title: ?[]const u8 = null,
};

pub fn findFeedLinks(allocator: *Allocator, contents: []const u8) !Page {
    // Remove first brackets from html '<!doctype html>'
    var start_index = mem.indexOfScalar(u8, contents, '>') orelse return error.InvalidHtml;
    start_index += 1;
    if (contents[start_index] == '\n') {
        start_index += 1;
    }

    var links = ArrayList(Link).init(allocator);
    defer links.deinit();

    var page_title: ?[]const u8 = null;

    var link_rel: ?[]const u8 = null;
    var link_type: ?[]const u8 = null;
    var link_title: ?[]const u8 = null;
    var link_href: ?[]const u8 = null;

    var active_tab = Tag.none;
    var iter = xml.Parser.init(contents[start_index..]);
    while (iter.next()) |event| {
        // warn("{}\n", .{event});
        switch (event) {
            .open_tag => |tag| {
                // warn("open_tag: {s}\n", .{tag});
                if (mem.eql(u8, "link", tag) or mem.eql(u8, "a", tag)) {
                    active_tab = .link_or_a;
                } else if (mem.eql(u8, "title", tag)) {
                    active_tab = .title;
                }
            },
            .close_tag => |tag| {
                // warn("close_tag: {s}\n", .{tag});
                switch (active_tab) {
                    .link_or_a => {
                        const valid_rel = link_rel != null and mem.eql(u8, "alternate", link_rel.?);
                        const valid_type = link_type != null;
                        if (valid_rel and valid_type) {
                            if (link_href) |href| {
                                var is_duplicate = blk: {
                                    for (links.items) |link| {
                                        if (mem.eql(u8, link.href, href)) {
                                            break :blk true;
                                        }
                                    }
                                    break :blk false;
                                };
                                if (!is_duplicate) {
                                    const media_type = blk: {
                                        if (mem.eql(u8, "application/rss+xml", link_type.?)) {
                                            break :blk MediaType.rss;
                                        } else if (mem.eql(u8, "application/atom+xml", link_type.?)) {
                                            break :blk MediaType.atom;
                                        }
                                        break :blk MediaType.unknown;
                                    };
                                    try links.append(Link{
                                        .href = href,
                                        .title = link_title,
                                        .media_type = media_type,
                                    });
                                }
                            }
                        }
                        link_rel = null;
                        link_type = null;
                        link_title = null;
                        link_href = null;
                        active_tab = .none;
                    },
                    .title => {
                        active_tab = .none;
                    },
                    .none => {},
                }
            },
            .attribute => |attr| {
                // warn("attribute\n", .{});
                // warn("\tname: {s}\n", .{attr.name});
                // warn("\traw_value: {s}\n", .{attr.raw_value});
                switch (active_tab) {
                    .link_or_a => {
                        if (mem.eql(u8, "rel", attr.name)) {
                            link_rel = attr.raw_value;
                        } else if (mem.eql(u8, "type", attr.name)) {
                            link_type = attr.raw_value;
                        } else if (mem.eql(u8, "title", attr.name)) {
                            link_title = attr.raw_value;
                        } else if (mem.eql(u8, "href", attr.name)) {
                            link_href = attr.raw_value;
                        }
                    },
                    .none, .title => {},
                }
            },
            .comment => |str| {
                // warn("comment: {s}\n", .{str});
            },
            .processing_instruction => |str| {
                // warn("processing_instruction: {s}\n", .{str});
            },
            .character_data => |value| {
                // warn("character_data: {s}\n", .{value});
                if (active_tab == .title) {
                    page_title = value;
                }
            },
        }
    }

    return Page{
        .title = page_title,
        .links = links.toOwnedSlice(),
    };
}

test "parse html" {
    const expect = testing.expect;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const html = @embedFile("../test/lobste.rs.html");
    const page = try findFeedLinks(allocator, html);
    expect(4 == page.links.len);
    expect(MediaType.rss == page.links[0].media_type);
}
