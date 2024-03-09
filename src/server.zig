const config = @import("app_config.zig");
const Datetime = @import("zig-datetime").datetime.Datetime;

// valid date for <time>. Example: "2011-11-18T14:54:39.929Z"
const date_fmt = "{[year]d}-{[month]d:0>2}-{[day]d:0>2}T{[hour]d:0>2}:{[minute]d:0>2}:{[second]d:0>2}.000Z";
const date_len_max = std.fmt.comptimePrint(date_fmt, .{
    .year = 2222,
    .month = 3,
    .day = 2,
    .hour = 2,
    .minute = 2,
    .second = 2,
}).len;

// For fast compiling and testing
pub fn main() !void {
    // try start();
    try page_root_render();
}

fn page_root_render() !void {
    var db = try Storage.init("./tmp/feeds.db");
    var general = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(general.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const feeds = try db.feeds_all(alloc);
    const feeds_rendered = try feeds_render(&db, alloc, feeds);
    _ = feeds_rendered;
    // const writer = std.io.getStdOut().writer();
    // try writer.writeAll(feeds_rendered);

}

const item_fmt = 
    \\<li>
    \\  <a href="{[link]s}">{[title]s}</a>
    \\  <time datetime="{[date]s}">{[date]s}</time>
    \\</li>
;

const item_no_fmt_len = std.fmt.comptimePrint(item_fmt, .{.link = "", .title = "", .date = ""}).len;
// title + link = 128
const average_item_len = item_no_fmt_len + date_len_max + 128;

fn feed_items_render(alloc: std.mem.Allocator, items: []FeedItemRender) ![]const u8 {
    if (items.len == 0) {
        return "";
    }

    const link_placeholder = "#";
    const title_placeholder = "[no-title]";
    var capacity = items.len * (item_no_fmt_len + 2 * date_len_max);
    for (items) |item| {
        capacity += if (item.title.len > 0) item.title.len else title_placeholder.len;
        capacity += if (item.link) |v| v.len else link_placeholder.len;
    }

    var date_buf: [date_len_max]u8 = undefined;
    var content = try std.ArrayList(u8).initCapacity(alloc, capacity);
    defer content.deinit();
    for (items) |item| {
        content.writer().print(item_fmt, .{
            .link = item.link orelse link_placeholder,
            .title = if (item.title.len > 0) item.title else title_placeholder,
            .date = timestampToString(&date_buf, item.updated_timestamp),
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
        \\ <time datetime="{[date]s}">{[date]s}</time>
        \\ <ul class="feed-items-list">{[items]s}</ul>
        \\</li>
    ;

    const no_fmt_len = comptime blk: {
        break :blk std.fmt.comptimePrint(li_html, .{.feed_url = "", .page_url = "", .title = "", .date = "", .items = ""}).len;
    };

    const link_placeholder = "#";
    const title_placeholder = "[no-title]";
    var capacity = feeds.len * (no_fmt_len + date_len_max);


    for (feeds) |feed| {
        capacity += (feed.page_url orelse link_placeholder).len;
        capacity += feed.feed_url.len;
        capacity += if (feed.title.len > 0) feed.title.len else title_placeholder.len;
        capacity += config.max_items * average_item_len;
    }

    var date_buf: [date_len_max]u8 = undefined;
    var content = try std.ArrayList(u8).initCapacity(alloc, capacity);
    defer content.deinit();
    for (feeds) |feed| {
        const items = try db.feed_items_with_feed_id(alloc, feed.feed_id);
        const items_rendered = try feed_items_render(alloc, items);

        try content.writer().print(li_html, .{
            .page_url = feed.page_url orelse link_placeholder,
            .title = if (feed.title.len > 0) feed.title else title_placeholder,
            .feed_url = feed.feed_url,
            .date = timestampToString(&date_buf, feed.updated_timestamp),
            .items = items_rendered,
        });
    }

    return try content.toOwnedSlice();
}

fn timestampToString(buf: []u8, timestamp: ?i64) []const u8 {
    if (timestamp) |ts| {
        const dt = Datetime.fromSeconds(@floatFromInt(ts));
        const date_args = .{
            .year = dt.date.year,
            .month = dt.date.month,
            .day = dt.date.day,
            .hour = dt.time.hour,
            .minute = dt.time.minute,
            .second = dt.time.second,
        };
        return std.fmt.bufPrint(buf, date_fmt, date_args) catch unreachable; 
    }

    return "";
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
