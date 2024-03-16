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
const title_placeholder = "[no-title]";

// For fast compiling and testing
pub fn main() !void {
    std.debug.print("RUN MAIN\n", .{});
    // try start();
    try start_tokamak();
}

const tk = @import("tokamak");

fn start_tokamak() !void {
    var general = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(general.allocator());
    defer arena.deinit();

    var db = try Storage.init("./tmp/feeds.db");

    var server = try tk.Server.start(arena.allocator(), handler, .{ 
        .injector = try tk.Injector.from(.{ &db }),
        .port = 8080, .n_threads = 2,
        .keep_alive = false,
    });
    server.wait();
}

const handler = tk.chain(.{
    tk.logger(.{}),
    tk.group("/", tk.router(routes)), // and this is our shorthand
    tk.send(error.NotFound),
});

const routes = struct {
    const root_html = @embedFile("./views/root.html");
    const base_layout = @embedFile("./layouts/base.html");

    pub fn @"GET /style.css"() []const u8 {
        return @embedFile("./style.css");
    }
    
    pub fn @"GET /"(ctx: *tk.Context, req: *tk.Request, resp: *tk.Response) !void {
        var search_value: ?[]const u8 = null;
        if (req.url.query) |query| {
            var iter = mem.splitSequence(u8, query, "&");
            while (iter.next()) |kv| {
                var kv_iter = mem.splitSequence(u8, kv, "=");
                const key = kv_iter.next() orelse break;
                if (mem.eql(u8, key, "search")) {
                    search_value = mem.trim(u8, kv_iter.next() orelse "", &std.ascii.whitespace);
                    std.debug.print("found: |{?s}|\n", .{search_value});
                }
            }
        }

        // TODO: for some reason not working
        if (search_value != null and search_value.?.len == 0) {
            try resp.noContent();
            try resp.setHeader("location", "/");
            resp.status = .permanent_redirect;
            return;
        }

        const db = try ctx.injector.get(*Storage);

        try resp.setHeader("content-type", "text/html");
        const w = try resp.writer(); 
        var base_iter = mem.splitSequence(u8, base_layout, "[content]");
        const head = base_iter.next() orelse unreachable;
        const foot = base_iter.next() orelse unreachable;

        try w.writeAll(head);

        try body_head_render(req.allocator, db, w, search_value orelse "");

        const feeds = blk: {
            if (search_value) |term| {
                const trimmed = std.mem.trim(u8, term, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    break :blk try db.feeds_search(req.allocator, trimmed);
                }
            }
            break :blk try db.feeds_all(req.allocator);
        };
        
        try w.writeAll("<ul>");
        for (feeds) |feed| {
            try w.writeAll("<li>");
            try feed_render(w, feed);

            const items = try db.feed_items_with_feed_id(req.allocator, feed.feed_id);
            try w.writeAll("<ul>");
            for (items) |item| {
                try w.writeAll("<li>");
                try item_render(w, item);
                try w.writeAll("</li>");
            }
            try w.writeAll("</ul>");

            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");

        try w.writeAll(foot);
    }
};

fn feed_render(w: anytype, feed: types.FeedRender) !void {
    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
    var date_display_buf: [16]u8 = undefined;
    var date_buf: [date_len_max]u8 = undefined;

    const feed_link_fmt = 
    \\<a href="{[page_url]s}">{[title]s}</a>
    \\<a href="{[feed_url]s}">Feed link</a>
    \\<time datetime="{[date]s}">{[date_display]s}</time>
    ;

    const feed_title_fmt =
    \\<p>{[title]s}</p>
    \\<a href="{[feed_url]s}">Feed link</a>
    \\<time datetime="{[date]s}">{[date_display]s}</time>
    ;

    const title = if (feed.title.len > 0) feed.title else title_placeholder;
    const date_display_val = if (feed.updated_timestamp) |ts| try date_display(&date_display_buf, now_sec, ts) else "";
    if (feed.page_url) |page_url| {
        try w.print(feed_link_fmt, .{
            .page_url = page_url,
            .title = title,
            .feed_url = feed.feed_url,
            .date = timestampToString(&date_buf, feed.updated_timestamp),
            .date_display = date_display_val,
        });
    } else {
        try w.print(feed_title_fmt, .{
            .title = title,
            .feed_url = feed.feed_url,
            .date = timestampToString(&date_buf, feed.updated_timestamp),
            .date_display = date_display_val,
        });
    }
}

fn item_render(w: anytype, item: FeedItemRender) !void {
    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
    var date_display_buf: [16]u8 = undefined;
    var date_buf: [date_len_max]u8 = undefined;

    const item_link_fmt =
    \\<a href="{[link]s}">{[title]s}</a>
    \\<time datetime="{[date]s}">{[date_display]s}</time>
    ;

    const item_title_fmt =
    \\<p>{[title]s}</p>
    \\<time datetime="{[date]s}">{[date_display]s}</time>
    ;
                
    const item_title = if (item.title.len > 0) item.title else title_placeholder;
    const item_date_display_val = if (item.updated_timestamp) |ts| try date_display(&date_display_buf, now_sec, ts) else "";

    if (item.link) |link| {
        try w.print(item_link_fmt, .{
            .title = item_title,
            .link = link,
            .date = timestampToString(&date_buf, item.updated_timestamp),
            .date_display = item_date_display_val,
        });
    } else {
        try w.print(item_title_fmt, .{
            .title = item_title,
            .date = timestampToString(&date_buf, item.updated_timestamp),
            .date_display = item_date_display_val,
        });
    }
}

fn body_head_render(allocator: std.mem.Allocator, db: *Storage, w: anytype, search_value: []const u8) !void {
    try w.writeAll("<header>");
    try w.writeAll(
      \\<a href="/">Home</a>
      \\<a href="/tags">Tags</a>
    );

    const tag_fmt = 
    \\<input type="checkbox" name="tag" id="tag-index-{[tag_index]d}" value="{[tag]s}" {[is_checked]s}>
    \\<label for="tag-index-{[tag_index]d}">{[tag]s}</label>
    ;

    const tag_link_fmt = 
    \\<a href="/tags?tag={[tag]s}">{[tag]s}</a>
    ;

    const tags = try db.tags_all(allocator);
    try w.writeAll("<form action='/tags'>");
    for (tags, 0..) |tag, i| {
        try w.writeAll("<span>");
        try w.print(tag_fmt, .{
            .tag = tag,
            .tag_index = i,
            .is_checked = "",
        });
        try w.print(tag_link_fmt, .{ .tag = tag });
        try w.writeAll("</span>");
    }
    try w.writeAll("<button>Filter tags</button>");
    try w.writeAll("</form>");

    const search_fmt = 
    \\<form method="GET">
    \\  <label for="search_value">Search feeds</label>
    \\  <input type="search" name="search" id="search_value" value="{[search]s}">
    \\  <button type="submit">Search feeds</button>
    \\</form>
    ;

    try w.print(search_fmt, .{ .search = search_value });

    try w.writeAll("</header>");
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

fn feed_items_render_old(alloc: std.mem.Allocator, items: []FeedItemRender) ![]const u8 {
    if (items.len == 0) {
        return "";
    }

    const link_placeholder = "#";
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
        const items_rendered = try feed_items_render_old(alloc, items);

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
        } else if (mem.eql(u8, path, "/feed")) {
            if (feed_page(req) catch false) {
                return;
            }
        }

        not_found(req);
    }

    pub fn feed_page(req: zap.Request) !bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        req.parseQuery();
        const id_raw = req.getParamSlice("id") orelse return false;
        std.debug.print("feed_id: {s}\n", .{id_raw});
        const feed_id = try std.fmt.parseUnsigned(usize, id_raw, 10);
        const feed = try db.feed_with_id(arena.allocator(), feed_id);

        if (feed == null) {
            return false;
        }

        var arr = try std.ArrayList(u8).initCapacity(arena.allocator(), 64 * 1024);
        defer arr.deinit();
        var writer = arr.writer();

        const content_needle = "[content]";
        var base_iter = mem.splitSequence(u8, base_html, content_needle);

        if (base_iter.next()) |html_start| {
            try writer.writeAll(html_start);
        } else {
            return error.FailedToWriteHtml;
        }

        const items = try db.feed_items_with_feed_id(arena.allocator(), feed.?.feed_id);

        if (req.getParamSlice("edit")) |_| {
            try feed_edit_page(writer, feed.?, items);
        } else {
            try feed_view_page(writer, feed.?, items);
        }

        if (base_iter.next()) |html_end| {
            try writer.writeAll(html_end);
        } else {
            return error.FailedToWriteHtml;
        }

        std.debug.assert(base_iter.next() == null);

        try req.setHeader("content-type", "text/html");
        try req.sendBody(arr.items);

        return true;
    }

    fn feed_view_page(writer: anytype, feed: types.FeedRender, items: []FeedItemRender) !void {
        try feed_render(writer, feed);
        const edit_html =
        \\<a href="?id={d}&edit=">Edit feed</a>
        ;
        try writer.print(edit_html, .{feed.feed_id});

        try feed_items_ul_render(writer, items);
    }
    

    // TODO: add delete button
    fn feed_edit_page(writer: anytype, feed: types.FeedRender, items: []FeedItemRender) !void {
        const form_fmt = 
        \\<a href="/feed?id={[feed_id]d}">Cancel feed edit / Back to feed page</a>
        \\<form method="POST">
        \\  <input type="hidden" name="feed_id" value="{[feed_id]d}">
        \\  <label for="feed-title">Feed title</label>
        \\  <input type="text" id="feed-title" name="title" value="{[title]s}">
        \\  <fieldset>
        \\    <legend>Tags</legend>
        \\  </fieldset>
        \\  <button>Edit feed</button>
        \\</form>
        ;
        const title = if (feed.title.len > 0) feed.title else "[no-title]";
        try writer.print(form_fmt, .{.feed_id = feed.feed_id, .title = title});

        try feed_items_ul_render(writer, items);
    }

    fn feed_items_ul_render(writer: anytype, items: []FeedItemRender) !void {
        try writer.writeAll("<ul>");
        for (items) |item| {
            try writer.writeAll("<li>");
            try feed_item_render(writer, item);
            try writer.writeAll("</li>");
        }
        try writer.writeAll("</ul>");
    }

    pub fn feed_item_render(writer: anytype, item: FeedItemRender) !void {
        const title = if (item.title.len > 0) item.title else "[no-title]";
        if (item.link) |link| {
            const page_url_fmt = 
            \\<a href="{[page_url]s}">{[title]s}</a>
            ;
            try writer.print(page_url_fmt, .{ 
                .page_url = link, 
                .title = title,  
            });
        } else {
            const title_fmt = 
            \\<p>{[title]s}</p>
            ;
            try writer.print(title_fmt, .{ .title = title });
        }

        if (item.updated_timestamp) |ts| {
            const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
            var date_display_buf: [16]u8 = undefined;
            var date_buf: [date_len_max]u8 = undefined;
            const time_fmt =
            \\<time datetime="{[date]s}">{[date_display]s}</time>
            ;
            const date_str = timestampToString(&date_buf, item.updated_timestamp);
            const date_display_str = try date_display(&date_display_buf, now_sec, ts);
            try writer.print(time_fmt, .{.date = date_str, .date_display = date_display_str});
        }
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
            \\<label for="tag-index-{[tag_index]d}">{[tag]s}</label>
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
        const tag_links = tags_render(&arena, &.{}) catch return; 

        const index_fmt = @embedFile("index.zig-fmt.html");
        const index_render = std.fmt.allocPrint(arena.allocator(), index_fmt, .{
            .feed_items = content,
            .search_value = search_value,
            .tag_links = tag_links,
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

    // const thread = try makeRequestThread(allocator, "http://127.0.0.1:3000/");
    // defer thread.join();    

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
