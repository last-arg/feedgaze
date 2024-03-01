// TODO: find out date's max len
const date_len_max = 10;

// For fast compiling and testing
pub fn main() !void {
    // try start();
    try page_root_render();
}

fn page_root_render() !void {
    const writer = std.io.getStdOut().writer();
    var db = try Storage.init("./tmp/feeds.db");
    var general = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(general.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const feeds = try db.feeds_all(alloc);
    const feeds_rendered = try feeds_render(&db, alloc, feeds);
    // _ = feeds_rendered;
    try writer.writeAll(feeds_rendered);

}

fn feed_items_render(alloc: std.mem.Allocator, items: []FeedItemRender) ![]const u8 {
    if (items.len == 0) {
        return "";
    }

    const li_html = 
        \\<li>
        \\  <a href="{[link]s}">{[title]s}</a>
        \\  <p>{[date]?d}</p>
        \\</li>
    ;
    const link_placeholder = "#";

    // TODO: over allocating because format placeholders.
    // Subtract lengths of placeholders from final capacity size.

    var capacity = items.len * (li_html.len + date_len_max);
    for (items) |item| {
        capacity += item.title.len;
        capacity += if (item.link) |v| v.len else link_placeholder.len;
    }

    var content = try std.ArrayList(u8).initCapacity(alloc, capacity);
    defer content.deinit();
    for (items) |item| {
        content.writer().print(li_html, .{
            .link = item.link orelse link_placeholder,
            .title = if (item.title.len > 0) item.title else "[no-title]",
            .date = item.updated_timestamp,
        }) catch unreachable;
    }

    return try content.toOwnedSlice();
}

fn feeds_render(db: *Storage, alloc: std.mem.Allocator, feeds: []types.FeedRender) ![]const u8 {
    if (feeds.len == 0) {
        return "";
    }
    const li_html = 
        \\<li>
        \\ <a href="{[page_url]s}">{[title]s}</a>
        \\ <a href="{[feed_url]s}">Feed url</a>
        \\ <p>{[date]?d}</p>
        \\ <ul class="feed-items-list">{[items]s}</ul>
        \\</li>
    ;

    // TODO: over allocating because format placeholders.
    // Subtract lengths of placeholders from final capacity size.

    var capacity = (li_html.len + date_len_max) * feeds.len;
    for (feeds) |feed| {
        const page_url_len = (feed.page_url orelse feed.feed_url).len;
        capacity += page_url_len;
        capacity += feed.feed_url.len;
        capacity += feed.title.len;
    }
    var content = try std.ArrayList(u8).initCapacity(alloc, capacity);
    defer content.deinit();
    for (feeds) |feed| {
        const items = try db.feed_items_with_feed_id(alloc, feed.feed_id);
        const items_rendered = try feed_items_render(alloc, items);

        content.writer().print(li_html, .{
            .page_url = feed.page_url orelse feed.feed_url,
            .title = feed.title,
            .feed_url = feed.feed_url,
            .date = feed.updated_timestamp,
            .items = items_rendered,
        }) catch unreachable;
    }
    return try content.toOwnedSlice();
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
const types = @import("./feed_types.zig");
const FeedItemRender = types.FeedItemRender;
const storage = @import("./storage.zig");
const Storage = storage.Storage;

const index_html = @embedFile("./index.html");
