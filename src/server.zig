// TODO: find out date's max len
const date_len_max = 10;

// For fast compiling and testing
pub fn main() !void {
    // try start();
    try renderRootPage();
}

fn renderRootPage() !void {
    const writer = std.io.getStdOut().writer();
    var db = try Storage.init("./tmp/feeds.db");
    var general = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(general.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const query_feed =
        \\select * from feed order by updated_timestamp DESC;
    ;
    const feeds = try storage.selectAll(&db.sql_db, alloc, FeedRender, query_feed, .{});
    const feeds_rendered = try renderFeedsList(alloc, feeds);
    _ = feeds_rendered;
    // try writer.print(index_html, .{ .feeds_list = feeds_rendered });

    const query_item =
        \\select title, link, updated_timestamp 
        \\from item where feed_id = ? order by updated_timestamp DESC, position ASC;
    ;
    const items = try storage.selectAll(&db.sql_db, alloc, FeedItemRender, query_item, .{1});

    const items_rendered = try renderFeedItemList(alloc, items);
    try writer.print("{s}\n", .{items_rendered});
}

fn renderFeedItemList(alloc: std.mem.Allocator, items: []FeedItemRender) ![]const u8 {
    const li_html = 
        \\<li>
        \\  <a href="{[link]s}">{[title]s}</a>
        \\  <p>{[date]?d}</p>
        \\</li>
    ;
    const link_placeholder = "#";

    // TODO: over allocating because format placeholders.
    // Subtract lengths of placeholders from final capacity size.

    var cap = items.len * (li_html.len + date_len_max);
    for (items) |item| {
        cap += item.title.len;
        cap += if (item.link) |v| v.len else link_placeholder.len;
    }

    var content = try std.ArrayList(u8).initCapacity(alloc, cap);
    defer content.deinit();
    for (items) |item| {
        content.writer().print(li_html, .{
            .link = item.link orelse link_placeholder,
            .title = if (item.title.len > 0) item.title else "<no-title>",
            .date = item.updated_timestamp,
        }) catch unreachable;
    }

    return try content.toOwnedSlice();
}

const FeedItemRender = struct {
    title: []const u8,
    link: ?[]const u8,
    updated_timestamp: ?i64,
};

const FeedRender = struct {
    feed_id: usize,
    title: []const u8,
    feed_url: []const u8,
    page_url: ?[]const u8,
    updated_timestamp: ?i64,
};

fn renderFeedsList(alloc: std.mem.Allocator, feeds: []FeedRender) ![]const u8 {
    if (feeds.len == 0) {
        return "";
    }
    const li_html = 
        \\<li>
        \\ <a href="{[page_url]s}">{[title]s}</a>
        \\ <a href="{[feed_url]s}">Feed url</a>
        \\ <p>{[date]?d}</p>
        \\ <ul class="feed-items-list"></ul>
        \\</li>
    ;
    // TODO: find lengths of format placeholders to get more accurate
    // allocation size. Currently over-allocating.

    var output_len = (li_html.len + date_len_max) * feeds.len;
    var page_url_max: usize = 0;
    var feed_url_max: usize = 0;
    var title_max: usize = 0;
    for (feeds) |feed| {
        const page_url_len = (feed.page_url orelse feed.feed_url).len;
        output_len += page_url_len;
        output_len += feed.feed_url.len;
        output_len += feed.title.len;
        if (page_url_len > page_url_max) {
            page_url_max = page_url_len;
        }
        if (feed.feed_url.len > feed_url_max) {
            feed_url_max = feed.feed_url.len;
        }
        if (feed.title.len > feed_url_max) {
            title_max = feed.title.len;
        }
    }
    const buf_size = li_html.len + page_url_max +  feed_url_max + title_max + date_len_max;
    const buf = try alloc.alloc(u8, buf_size);
    defer alloc.free(buf);
    var body = try std.ArrayList(u8).initCapacity(alloc, output_len);
    defer body.deinit();
    for (feeds) |feed| {
        const feed_html = try std.fmt.bufPrint(buf, li_html, .{
            .page_url = feed.page_url orelse feed.feed_url,
            .title = feed.title,
            .feed_url = feed.feed_url,
            .date = feed.updated_timestamp,
        });
        body.appendSliceAssumeCapacity(feed_html);
    }
    return try body.toOwnedSlice();
}

fn start() !void {
    try std.io.getStdOut().writeAll("hello\n");
    var listener = zap.HttpListener.init(.{
        .port = 3000,
        .on_request = on_request,
        .log = true,
    });
    try listener.listen();

    std.log.debug("Listening on 0.0.0.0:3000\n", .{});

    // start worker threads
    zap.start(.{
        .threads = 2,
        .workers = 2,
    });
}

fn on_request(r: zap.Request) void {
    if (r.path) |the_path| {
        std.debug.print("PATH: {s}\n", .{the_path});
    }

    if (r.query) |the_query| {
        std.debug.print("QUERY: {s}\n", .{the_query});
    }
    // Routes:
    // 1) / - display most recently updated feeds
    //    Have a search box that filters based on page and feed url?
    r.sendBody(index_html) catch return;
}

const std = @import("std");
const zap = @import("zap");
const storage = @import("./storage.zig");
const Storage = storage.Storage;

const index_html = @embedFile("./index.html");

fn p() void {
    std.debug.print("fn\n", .{});
}

test "tmp" {
    std.debug.print("hello\n", .{});
    p();
    p();
}
