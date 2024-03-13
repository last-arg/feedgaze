// Date for machine "2011-11-18T14:54:39.929Z". For <time datetime="...">.
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
    std.debug.print("RUN MAIN\n", .{});
    try start();
    
    // var general = std.heap.GeneralPurposeAllocator(.{}){};
    // var arena = std.heap.ArenaAllocator.init(general.allocator());
    // defer arena.deinit();
    // const r = try page_root_render(&arena);
    // std.debug.print("{s}\n", .{r});
}

fn date_display(buf: []u8, a: i64, b: i64) ![]const u8 {
    if (a < b) {
        const dt = Datetime.fromSeconds(@floatFromInt(b));
        // fallback date format: 01 Jan 2014
        return try std.fmt.bufPrint(buf, "{d:0>2} {s} {d}", .{dt.date.day, dt.date.monthName()[0..3], dt.date.year});
    }

    const diff = a - b;
    const mins = @divFloor(diff, 60);
    const hours = @divFloor(mins, 60);
    const days = @divFloor(hours, 24);
    const months = @divFloor(days, 30);
    const years = @divFloor(days, 365);

    if (years > 0) {
        return try std.fmt.bufPrint(buf, "{d}Y", .{years});
    } else if (months > 0) {
        return try std.fmt.bufPrint(buf, "{d}M", .{months});
    } else if (days > 0) {
        return try std.fmt.bufPrint(buf, "{d}d", .{days});
    } else if (hours > 0) {
        return try std.fmt.bufPrint(buf, "{d}h", .{hours});
    } else if (mins == 0) {
        return try std.fmt.bufPrint(buf, "0m", .{});
    }

    // mins > 0
    return try std.fmt.bufPrint(buf, "{d}m", .{mins});
}

const item_fmt = 
    \\<li>
    \\  <a href="{[link]s}">{[title]s}</a>
    \\  <time datetime="{[date]s}">{[date_display]s}</time>
    \\</li>
;

const item_no_fmt_len = std.fmt.comptimePrint(item_fmt, .{.link = "", .title = "", .date = "", .date_display = ""}).len;
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

    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
    var date_display_buf: [16]u8 = undefined;

    var date_buf: [date_len_max]u8 = undefined;
    var content = try std.ArrayList(u8).initCapacity(alloc, capacity);
    defer content.deinit();
    for (items) |item| {
        content.writer().print(item_fmt, .{
            .link = item.link orelse link_placeholder,
            .title = if (item.title.len > 0) item.title else title_placeholder,
            .date = timestampToString(&date_buf, item.updated_timestamp),
            .date_display = if (item.updated_timestamp) |ts| try date_display(&date_display_buf, now_sec, ts) else "",
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
        \\ <a href="{[feed_url]s}">Feed link</a>
        \\ <time datetime="{[date]s}">{[date_display]s}</time>
        \\ <ul class="feed-items-list">{[items]s}</ul>
        \\</li>
    ;

    const no_fmt_len = comptime blk: {
        break :blk std.fmt.comptimePrint(li_html, .{.feed_url = "", .page_url = "", .title = "", .date = "", .items = "", .date_display = ""}).len;
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

    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
    var date_display_buf: [16]u8 = undefined;

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
            .date_display = if (feed.updated_timestamp) |ts| try date_display(&date_display_buf, now_sec, ts) else "",
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

const PageHandler = struct {
    allocator: std.mem.Allocator,
    db: Storage,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: Storage) Self {
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

};

const Handler = struct {
    var allocator: std.mem.Allocator = undefined;
    var db: Storage = undefined;

    fn on_request(req: zap.Request) void {
        const path = req.path orelse return;

        if (path.len == 0 or mem.eql(u8, path, "/")) {
            root_page(req);
            return;
        } else if (mem.eql(u8, path, "/tags")) {
            tags_page(req);
            return;
        }

        not_found(req);
    }

    pub fn tags_page(req: zap.Request) void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var tags_arr = std.ArrayList([]const u8).init(arena.allocator());
        var iter = req.getParamSlices();
        while (iter.next()) |param| {
            if (mem.eql(u8, param.name, "tag")) {
                tags_arr.append(param.value) catch return;
            }
        }

        const tags_fmt = @embedFile("./tags.zig-fmt.html");
        // get feeds' with tags
        const feeds = db.feeds_with_tags(arena.allocator(), tags_arr.items) catch return;
        std.debug.print("len: {d}\n", .{feeds.len});
        const feeds_rendered = feeds_render(&db, arena.allocator(), feeds) catch return;

        const tag_links = tags_render(&arena, tags_arr.items) catch return; 
        const page_content = std.fmt.allocPrint(arena.allocator(), tags_fmt, .{
            .feed_items = feeds_rendered,
            .tag_links = tag_links,
        }) catch return;

        const content_needle = "[content]";
        const html = mem.replaceOwned(u8, arena.allocator(), base_html, content_needle, page_content) catch return;

        req.setHeader("content-type", "text/html") catch return;
        req.sendBody(html) catch return;
    }

    fn tags_render(arena: *std.heap.ArenaAllocator, tags_checked: [][]const u8) ![]const u8 {
        const a_html = 
            \\<input type="checkbox" name="tag" id="tag-index-{[tag_index]d}" value="{[tag]s}" {[is_checked]s}>
            \\<label for="tag-index-{[tag_index]d}">{[tag]s}<label>
            \\<a href="/tags?tag={[tag]s}">{[tag]s}</a>
        ;

        const tags = try db.tags_all(arena.allocator());
        var content = std.ArrayList(u8).init(arena.allocator());
        defer content.deinit();
        for (tags, 0..) |tag, i| {
            const is_checked = blk: {
                for (tags_checked) |tag_checked| { 
                    if (mem.eql(u8, tag_checked, tag)) { break :blk "checked"; }
                }
                break :blk "";
            };
            // TODO: might need to encode tag for href
            try content.writer().print(a_html, .{ .tag = tag, .tag_index= i, .is_checked = is_checked });
        }

        return try content.toOwnedSlice();
    }

    pub fn root_page(req: zap.Request) void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        req.parseQuery();

        const search_term = req.getParamSlice("search_value");
        if (search_term) |value| {
            const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len == 0) {
                req.redirectTo("/", null) catch return;
                return;
            }
        }

        const content = root_content_render(&arena, search_term) catch |err| {
            std.log.warn("{}\n", .{err});
            return;
        };
        const search_value = search_term orelse "";

        const index_fmt = @embedFile("index.zig-fmt.html");
        const index_render = std.fmt.allocPrint(arena.allocator(), index_fmt, .{
            .feed_items = content,
            .search_value = search_value,
        }) catch return;

        const content_needle = "[content]";

        const html = mem.replaceOwned(u8, arena.allocator(), base_html, content_needle, index_render) catch return;

        req.setHeader("content-type", "text/html") catch return;
        req.sendBody(html) catch |err| {
            std.log.warn("{}\n", .{err});
            return;
        };
    }

    fn root_content_render(arena: *std.heap.ArenaAllocator, search_term: ?[]const u8) ![]const u8 {
        const alloc = arena.allocator();
        const feeds = blk: {
            if (search_term) |term| {
                const trimmed = std.mem.trim(u8, term, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    break :blk try db.feeds_search(alloc, trimmed);
                }
            }
            break :blk try db.feeds_all(alloc);
        };
        const feeds_rendered = try feeds_render(&db, alloc, feeds);
        return feeds_rendered;
    }
};

fn start() !void {
    try std.io.getStdOut().writeAll("hello\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    const allocator = gpa.allocator();
    const db = try Storage.init("./tmp/feeds.db");
    
    zap.enableDebugLog();
    Handler.allocator = allocator;
    Handler.db = db;
    var listener = zap.HttpListener.init(.{
        .port = 3000,
        .on_request = Handler.on_request,
        .log = true,
    });
    try listener.listen();

    std.log.debug("Listening on 0.0.0.0:3000\n", .{});

    const thread = try makeRequestThread(allocator, "http://127.0.0.1:3000/");
    defer thread.join();    

    // start worker threads
    zap.start(.{
        .threads = 1,
        .workers = 1,
    });

    // show potential memory leaks when ZAP is shut down
    const has_leaked = gpa.detectLeaks();
    std.log.debug("Has leaked: {}\n", .{has_leaked});
}

fn not_found(req: zap.Request) void {
    req.setStatus(.not_found);
    req.sendBody("Not found") catch return;
}

fn makeRequest(a: std.mem.Allocator, url: []const u8) !void {
    const uri = try std.Uri.parse(url);

    var http_client: std.http.Client = .{ .allocator = a };
    defer http_client.deinit();

    _ = try http_client.fetch(.{ .location = .{.uri = uri} });
}

fn makeRequestThread(a: std.mem.Allocator, url: []const u8) !std.Thread {
    return try std.Thread.spawn(.{}, makeRequest, .{ a, url });
}

// fn gzip_compress_example() {
//     if (req.getHeader("accept-encoding")) |value| {
//         var html_stream =  std.io.fixedBufferStream(html);
//         var html_arr = std.ArrayList(u8).init(arena.allocator());
//         std.debug.print("accept: {s}\n", .{value});
//         std.compress.gzip.compress(html_stream.reader(), html_arr.writer(), .{}) catch return;
//         html = html_arr.items;
//         req.setHeader("Content-Encoding", "gzip") catch return;
//     }
// }

const std = @import("std");
const zap = @import("zap");
const types = @import("./feed_types.zig");
const FeedItemRender = types.FeedItemRender;
const storage = @import("./storage.zig");
const Storage = storage.Storage;
const config = @import("app_config.zig");
const Datetime = @import("zig-datetime").datetime.Datetime;
const base_html = @embedFile("./base.html");
const mem = std.mem;
