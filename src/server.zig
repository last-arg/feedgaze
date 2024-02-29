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
    
    const Result = struct {
        feed_id: usize,
        title: []const u8,
        feed_url: []const u8,
        page_url: ?[]const u8,
        updated_timestamp: ?i64,
    };
    const query =
        \\select * from feed order by updated_timestamp DESC;
    ;
    const feeds = try storage.selectAll(&db.sql_db, alloc, Result, query, .{});
    std.debug.print("feeds.len: {d}\n", .{feeds.len});
    std.debug.print("feeds: {}\n", .{feeds[0]});
    const li_html =
    \\<li>
    \\ <a href="{[page_url]s}">{[title]s}</a>
    \\ <a href="{[feed_url]s}">Feed url</a>
    \\ <p>{[date]?d}</p>
    \\ <ul class="feed-items-list"></ul>
    \\</li>
    ;
    for (feeds) |feed| {
        const feed_html = try std.fmt.allocPrint(alloc, li_html, .{
           .page_url = feed.page_url orelse feed.feed_url,
           .title = feed.title,
           .feed_url = feed.feed_url,
           .date = feed.updated_timestamp,
        });
        std.debug.print("{s}\n", .{feed_html});
    }
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
    r.sendBody(root_body) catch return;
}

const std = @import("std");
const zap = @import("zap");
const storage = @import("./storage.zig");
const Storage = storage.Storage;

const root_body = @embedFile("./index.html");

fn p() void {
    std.debug.print("fn\n", .{});
}

test "tmp" {
    std.debug.print("hello\n", .{});
    p();
    p();
}
