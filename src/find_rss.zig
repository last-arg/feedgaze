const std = @import("std");
const xml = @import("xml");
const warn = std.debug.warn;
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const l = std.log;

// can find rss link inside html
// <link rel="alternate" type="application/rss+xml" title="RSS Feed" href="https://www.sourcedomain.com/feed/" />
//
// In HTML 5 link element can appear in body
// https://webmasters.stackexchange.com/questions/55130/can-i-use-link-tags-in-the-body-of-an-html-document
//
// https://developer.mozilla.org/en-US/docs/Archive/RSS/Getting_Started/Syndicating

// https://tfrommen.de/how-to-detect-wordpress-websites/
// wordpress sites feed is located in <url>/feed/
// However, with the release of WordPress 4.4, the REST API started to send a Link header containing the URL of the REST API endpoint, which is <*/wp-json/>; rel="https://api.w.org/".

const Tag = enum {
    none,
    link_or_a,
};
const Link = struct {
    href: []const u8,
    title: ?[]const u8 = null,
};
pub fn findFeedLinks(allocator: *Allocator, contents: []const u8) ![]Link {
    // Remove first brackets from html '<!doctype html>'
    var start_index = mem.indexOfScalar(u8, contents, '>') orelse return error.InvalidHtml;
    start_index += 1;
    if (contents[start_index] == '\n') {
        start_index += 1;
    }

    var links = ArrayList(Link).init(allocator);
    defer links.deinit();

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
                if (mem.eql(u8, "link", tag) or mem.eql(u8, "a", tag)) {
                    active_tab = .link_or_a;
                    warn("open_tag: {s}\n", .{tag});
                }
            },
            .close_tag => |tag| {
                // warn("close_tag: {s}\n", .{tag});
                if (active_tab == .link_or_a) {
                    const valid_rel = link_rel != null and mem.eql(u8, "alternate", link_rel.?);
                    const valid_type = link_type != null and mem.eql(u8, "application/rss+xml", link_type.?);
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
                                try links.append(Link{
                                    .href = href,
                                    .title = link_title,
                                });
                            }
                        }
                    }
                    link_rel = null;
                    link_type = null;
                    link_title = null;
                    link_href = null;
                    active_tab = .none;
                }
            },
            .attribute => |attr| {
                // warn("attribute\n", .{});
                if (active_tab == .link_or_a) {
                    warn("\tname: {s}\n", .{attr.name});
                    warn("\traw_value: {s}\n", .{attr.raw_value});
                    if (mem.eql(u8, "rel", attr.name)) {
                        link_rel = attr.raw_value;
                    } else if (mem.eql(u8, "type", attr.name)) {
                        link_type = attr.raw_value;
                    } else if (mem.eql(u8, "title", attr.name)) {
                        link_title = attr.raw_value;
                    } else if (mem.eql(u8, "href", attr.name)) {
                        link_href = attr.raw_value;
                    }
                }
            },
            .comment => |str| {
                // warn("comment: {s}\n", .{str});
            },
            .processing_instruction => |str| {
                warn("processing_instruction: {s}\n", .{str});
            },
            .character_data => |value| {
                // warn("character_data: {s}\n", .{value});
            },
        }
    }

    return links.toOwnedSlice();
}

pub fn isDuplicateHref(links: []Link, href: []const u8) bool {}

test "parse html" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const html = @embedFile("../test/lobste.rs.html");
    const links = try findFeedLinks(allocator, html);
    // warn("len: {}\n", .{links.len});
    for (links) |link| {
        warn("link: {s}\n", .{link.href});
    }
}
