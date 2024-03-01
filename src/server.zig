// For fast compiling and testing
pub fn main() !void {
    // try start();
    try renderRootPage();
}

fn renderRootPage() !void {
    var db = try Storage.init("./tmp/feeds.db");
    var general = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(general.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const query =
        \\select * from feed order by updated_timestamp DESC;
    ;
    const feeds = try storage.selectAll(&db.sql_db, alloc, FeedRender, query, .{});
    const feeds_list = try renderFeedsList(alloc, feeds);
    // _ = feeds_list;
    try std.io.getStdOut().writer().print(index_html, .{ .feeds_list = feeds_list });
}

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
    // allocate size. Currently over-allocating.

    const date_max = 10;
    var output_len = (li_html.len + date_max) * feeds.len;
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
    const buf_size = li_html.len + page_url_max +  feed_url_max + title_max + date_max;
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
