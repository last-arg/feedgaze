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
const untagged = "[untagged]";

// For fast compiling and testing
pub fn main() !void {
    std.debug.print("RUN SERVER\n", .{});
    try start_server();
}

const Global = struct {
    storage: Storage, 

    pub fn init() !@This() {
        return .{
            .storage = try Storage.init("./tmp/feeds.db"),
        };
    }
};

fn start_server() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global = try Global.init();
    var server = try httpz.ServerCtx(*Global, *Global).init(allocator, .{.port = 5882}, &global);
    
    // overwrite the default notFound handler
    // server.notFound(notFound);

    // overwrite the default error handler
    // server.errorHandler(errorHandler); 

    var router = server.router();

    // use get/post/put/head/patch/options/delete
    // you can also use "all" to attach to all methods
    router.get("/", root_get);
    router.get("/tags", tags_get);
    router.get("/style.css", style_get);

    // start the server in the current thread, blocking.
    try server.listen(); 
}

fn style_get(_: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    resp.content_type = .CSS;
    const file = try std.fs.cwd().openFile("./public/style.css", .{});
    defer file.close();

    resp.body = try file.readToEndAlloc(req.arena, std.math.maxInt(u32));
}

fn tags_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;
    resp.content_type = .HTML;

    const w = resp.writer(); 
    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    try body_head_render(req.arena, db, w, .{});

    const tags = try db.tags_all_with_ids(req.arena);
    try w.writeAll("<h2>Tags</h2>");
    try w.writeAll("<ul>");
    for (tags) |tag| {
        try w.writeAll("<li>");
        try w.print("{d} - ", .{tag.tag_id});
        try tag_link_print(w, tag.name);
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>");

    try w.writeAll(foot);
}

// TODO: try to split base to head and foot during comptime
const base_layout = @embedFile("./layouts/base.html");

fn root_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    resp.content_type = .HTML;

    const w = resp.writer(); 
    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    const query = try req.query();
    const search_value = query.get("search");
    // TODO?: redirect if there search_value is empty?
    print("search: {?s}\ng", .{search_value});

    var tags_active = try std.ArrayList([]const u8).initCapacity(req.arena, query.len);
    defer tags_active.deinit();

    for (query.keys[0..query.len], query.values[0..query.len]) |key, value| {
        if (mem.eql(u8, "tag", key)) {
            const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                tags_active.appendAssumeCapacity(trimmed);
            }
        }
    }

    try body_head_render(req.arena, db, w, .{ 
        .search = search_value orelse "", 
        .tags_checked = tags_active.items, 
        .has_untagged = query.get("untagged") != null,
    });

    const feeds = blk: {
        const after = after: {
            if (query.get("after")) |value| {
                const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    break :after std.fmt.parseInt(usize, trimmed, 10) catch null;
                }
            }
            break :after null;
        };

        const is_tags_only = query.get("tags-only") != null;
        if (tags_active.items.len > 0) {
            if (!is_tags_only and search_value != null and search_value.?.len > 0) {
                const value = search_value.?;
                break :blk try db.feeds_search_with_tags(req.arena, value, tags_active.items, after);
            } else {
                break :blk try db.feeds_with_tags(req.arena, tags_active.items, after);
            }
        }

        if (!is_tags_only) {
            if (search_value) |term| {
                const trimmed = std.mem.trim(u8, term, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    break :blk try db.feeds_search(req.arena, trimmed, after);
                }
            }
        }

        break :blk try db.feeds_page(req.arena, after);
    };

    try w.writeAll("<main>");
    if (feeds.len > 0) {
        try feeds_and_items_print(w, req.arena, db, feeds);
        if (feeds.len == config.query_feed_limit) {
            var new_url_arr = try std.ArrayList(u8).initCapacity(req.arena, 128);
            defer new_url_arr.deinit();
            new_url_arr.appendSliceAssumeCapacity("/?");
            const href_next = blk: {
                for (query.keys[0..query.len], query.values[0..query.len]) |key, value| {
                    if (mem.eql(u8, "after", key)) {
                        continue;
                    }
                    try new_url_arr.appendSlice(key);
                    try new_url_arr.append('=');
                    try new_url_arr.appendSlice(value);
                    try new_url_arr.append('&');
                }

                try new_url_arr.appendSlice("after");
                try new_url_arr.append('=');
                const id_last = feeds[feeds.len - 1].feed_id;
                try new_url_arr.writer().print("{d}", .{id_last});

                break :blk new_url_arr.items;
            };
            try w.print(
                \\<a href="{s}">Next</a>
            , .{href_next});
        }
    } else {
        try w.writeAll(
            \\<p>Nothing to show</p>
        );
    }
    try w.writeAll("</main>");

    try w.writeAll(foot);
}

fn feeds_and_items_print(w: anytype, allocator: std.mem.Allocator,  db: *Storage, feeds: []types.FeedRender) !void {
    try w.writeAll("<ul>");
    for (feeds) |feed| {
        try w.writeAll("<li>");
        try feed_render(w, feed);
        try feed_edit_link_render(w, feed.feed_id);

        const tags = try db.feed_tags(allocator, feed.feed_id);
        if (tags.len > 0) {
            try w.writeAll("<div>");
            for (tags) |tag| {
                try tag_link_print(w, tag);
            }
            try w.writeAll("</div>");
        }
        
        const items = try db.feed_items_with_feed_id(allocator, feed.feed_id);
        if (items.len == 0) {
            continue;
        }
        try w.writeAll("<ul class='flow'>");
        for (items) |item| {
            try w.writeAll("<li class='feed-item'>");
            try item_render(w, item);
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");

        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>");
}

fn feed_edit_link_render(w: anytype, feed_id: usize) !void {
    const edit_fmt = 
    \\<a href="/feeds/{d}">Edit feed</a>
    ;
    try w.print(edit_fmt, .{ feed_id });
}

fn item_render(w: anytype, item: FeedItemRender) !void {
    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
    var date_display_buf: [16]u8 = undefined;
    var date_buf: [date_len_max]u8 = undefined;

    const item_link_fmt =
    \\<a href="{[link]s}" class="truncate" title="{[title]s}">{[title]s}</a>
    \\<time datetime="{[date]s}">{[date_display]s}</time>
    ;

    const item_title_fmt =
    \\<p class="truncate" title="{[title]s}">{[title]s}</p>
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

const HeadOptions = struct {
    search: []const u8 = "",
    tags_checked: [][]const u8 = &.{},
    has_untagged: bool = false,
};

fn body_head_render(allocator: std.mem.Allocator, db: *Storage, w: anytype, opts: HeadOptions) !void {
    try w.writeAll("<header>");
    try w.writeAll("<h1>feedgaze</h1>");
    try w.writeAll(
      \\<a href="/">Home/Feeds</a>
      \\<a href="/tags">Tags</a>
    );

    const tags = try db.tags_all(allocator);
    try w.writeAll("<form action='/'>");
    // This makes is the default action of form. For example used when pressing
    // enter inside input text field.
    try w.writeAll(
    \\  <button style="display: none">Default form action</button>
    );
    try w.writeAll("<fieldset>");
    try w.writeAll("<legend>Tags</legend>");

    // TODO: pass has_untagged value
    try untagged_label_render(w, opts.has_untagged);

    for (tags, 0..) |tag, i| {
        try tag_label_render(w, tag, i + 1, opts.tags_checked);
    }
    try w.writeAll("</fieldset>");
    try w.writeAll("<button name='tags-only'>Filter tags only</button>");

    try w.print(
    \\  <label for="search_value">Search feeds</label>
    \\  <input type="search" name="search" id="search_value" value="{s}">
    \\  <button>Filter</button>
    , .{ opts.search });

    try w.writeAll("</form>");
    try w.writeAll("</header>");
}

fn untagged_label_render(w: anytype, has_untagged: bool) !void {
    try w.writeAll("<div>");
    const is_checked: []const u8 = if (has_untagged) "checked" else "";
    const tag_fmt = 
    \\<span class="tag">
    \\<input type="checkbox" name="untagged" id="untagged" {[is_checked]s}>
    \\<label class="visually-hidden" for="untagged">{[value]s}</label>
    \\</span>
    ;
    try w.print(tag_fmt, .{ .value = untagged, .is_checked = is_checked });
    try w.print("<a href='/?untagged='>{s}</a>", .{ untagged });
    try w.writeAll("</div>");
}

fn tag_label_render(w: anytype, tag: []const u8, index: usize, tags_checked: [][]const u8) !void {
    try w.writeAll("<div>");
    var is_checked: []const u8 = "";
    for (tags_checked) |tag_checked| {
        if (mem.eql(u8, tag, tag_checked)) {
            is_checked = "checked";
            break;
        }
    }
    try tag_input_render(w, .{
        .tag = tag,
        .tag_index = index,
        .is_checked = is_checked,
    });
    try tag_link_print(w, tag);
    try w.writeAll("</div>");
}

const InputRenderArgs = struct{
    tag: []const u8, 
    tag_index: usize, 
    is_checked: []const u8,
    prefix: []const u8 = "tag-id-",
};

fn tag_input_render(w: anytype, args: InputRenderArgs) !void {
    const tag_fmt = 
    \\<span class="tag">
    \\<input type="checkbox" name="tag" id="{[prefix]s}{[tag_index]d}" value="{[tag]s}" {[is_checked]s}>
    \\<label class="visually-hidden" for="{[prefix]s}{[tag_index]d}">{[tag]s}</label>
    \\</span>
    ;
    try w.print(tag_fmt, args);
}

fn tag_link_print(w: anytype, tag: []const u8) !void {
    const tag_link_fmt = 
    \\<a href="/?tag={[tag]s}">{[tag]s}</a>
    ;
    
    try w.print(tag_link_fmt, .{ .tag = tag });
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

const std = @import("std");
const httpz = @import("httpz");
const Storage = @import("storage.zig").Storage;
const print = std.debug.print;
const mem = std.mem;
const types = @import("./feed_types.zig");
const Datetime = @import("zig-datetime").datetime.Datetime;
const FeedItemRender = types.FeedItemRender;
const config = @import("app_config.zig");
