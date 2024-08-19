// Date for machine "2011-11-18T14:54:39.929Z". For <time datetime="...">.
const date_fmt = "{[year]d}-{[month]d:0>2}-{[day]d:0>2}T{[hour]d:0>2}:{[minute]d:0>2}:{[second]d:0>2}.000Z";
const date_len_max = std.fmt.count(date_fmt, .{
    .year = 2222,
    .month = 3,
    .day = 2,
    .hour = 2,
    .minute = 2,
    .second = 2,
});

const title_placeholder = "[no-title]";
const untagged = "[untagged]";

// For fast compiling and testing
pub fn main() !void {
    const storage = try Storage.init("tmp/feeds.db");
    try start_server(storage, .{.port = 5882 });
}

const Global = struct {
    storage: Storage, 
};

pub fn start_server(storage: Storage, opts: types.ServerOptions) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global = .{ .storage = storage };
    const server_config = .{
        .port = opts.port,  
        .request = .{
            .max_form_count = 10,
        }
    };
    var server = try httpz.ServerCtx(*Global, *Global).init(allocator, server_config, &global);
    
    // overwrite the default notFound handler
    // server.notFound(notFound);

    // overwrite the default error handler
    // server.errorHandler(errorHandler); 

    var router = server.router();

    // use get/post/put/head/patch/options/delete
    // you can also use "all" to attach to all methods
    router.get("/", latest_added_get);
    router.get("/feeds", feeds_get);
    router.get("/tags", tags_get);
    router.get("/feed/:id", feed_get);
    router.post("/feed/:id", feed_post);
    router.post("/feed/:id/delete", feed_delete);
    router.get("/public/*", public_get);
    router.get("/favicon.ico", favicon_get);

    std.log.info("Server started at 'http://localhost:{d}'", .{opts.port});
    // start the server in the current thread, blocking.
    try server.listen(); 
}

fn feed_delete(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const feed_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const feed_id = std.fmt.parseUnsigned(usize, feed_id_raw, 10) catch return error.InvalidIdParam;

    const db = &global.storage;
    resp.status = 301;
    db.deleteFeed(feed_id) catch {
        // On failure redirect to feed page. Display error message
        const url_redirect = try std.fmt.allocPrint(req.arena, "/feed/{d}/?error=delete", .{feed_id});
        resp.header("Location", url_redirect);
        return;
    };

    resp.header("Location", "/?msg=delete");
}

fn feed_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const feed_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const feed_id = std.fmt.parseUnsigned(usize, feed_id_raw, 10) catch return error.InvalidIdParam;

    const form_data = try req.formData();
    const title = form_data.get("title") orelse return error.MissingFormFieldPageTitle;
    const page_url = form_data.get("page_url") orelse return error.MissingFormFieldPageUrl;
    const icon_url = form_data.get("icon_url") orelse return error.MissingFormFieldIconUrl;

    var tags = std.ArrayList([]const u8).init(req.arena);
    defer tags.deinit();
    for (form_data.keys[0..form_data.len], form_data.values[0..form_data.len]) |key, value| {
        if (mem.eql(u8, "tag", key)) {
            try tags.append(value);
        }
    }

    const new_tags = form_data.get("new_tags") orelse return error.MissingFormFieldNewTags;
    var tags_iter = mem.splitScalar(u8, new_tags, ',');
    while (tags_iter.next()) |tag_raw| {
        const tag = mem.trim(u8, tag_raw, &std.ascii.whitespace);
        if (tag.len > 0) {
            try tags.append(tag);
        }
    }

    resp.status = 301;
    const fields = .{
        .feed_id = feed_id,
        .title = title,
        .page_url = page_url,
        .icon_url = icon_url,
        .tags = tags.items,
    };
    const db = &global.storage;
    db.update_feed_fields(req.arena, fields) catch {
        const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error=", .{req.url.path});
        resp.header("Location", url_redirect);
        return;
    };

    const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?success=", .{req.url.path});
    resp.header("Location", url_redirect);
}

fn feed_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;
    const id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const id = std.fmt.parseUnsigned(usize, id_raw, 10) catch return error.InvalidIdParam;
    const feed = db.feed_with_id(req.arena, id) catch {
        return error.DatabaseFailure;
    } orelse {
        resp.status = 404;
        resp.body = "Feed not found";
        return;
    };

    const tags_all = db.tags_all(req.arena) catch blk: {
        std.log.warn("Request '/feed/{d}' failed to get all tags", .{feed.feed_id});
        break :blk &.{};
    };

    const feed_tags = db.feed_tags(req.arena, feed.feed_id) catch blk: {
        std.log.warn("Request '/feed/{d}' failed to get feed tags", .{feed.feed_id});
        break :blk &.{};
    };

    const items = db.feed_items_with_feed_id(req.arena, feed.feed_id) catch blk: {
        std.log.warn("Request '/feed/{d}' failed to get feed items", .{feed.feed_id});
        break :blk &.{};
    };

    const w = resp.writer();

    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    try body_head_render(req, db, w, .{});

    try w.writeAll("<main>");
    try w.writeAll("<div class='feed-info'>");
    try w.writeAll("<h2>");
    if (feed.icon_url) |icon_url| {
        try w.print("<img src='{s}'>", .{icon_url});
    }
    try w.writeAll(if (feed.title.len > 0) feed.title else feed.page_url orelse feed.feed_url);
    try w.writeAll("</h2>");
    try w.writeAll("<p>Page url: ");
    if (feed.page_url) |page_url| {
        try w.print(
        \\<a href="{s}" class="inline-block">{s}</a>
        , .{page_url, page_url});
    } else {
        try w.writeAll("no url");
    }
    try w.writeAll("</p>");

    try w.print(
        \\<p>Feed url: <a href="{[feed_url]s}">{[feed_url]s}</a></p>
    , .{ .feed_url = feed.feed_url });

    var date_buf: [date_len_max]u8 = undefined;
    var relative_buf: [32]u8 = undefined;
    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());

    if (try db.feed_last_update(feed.feed_id)) |last_update| {
        const seconds = now_sec - last_update;
        try w.print(
            \\<p>Last update was <time datetime="{s}">{s}</time> ago</p>
        , .{ timestampToString(&date_buf, last_update), try relative_time_from_seconds(&relative_buf, seconds)});
    }

    if (try db.next_update_feed(feed.feed_id)) |utc_sec| {
        const ts = now_sec + utc_sec;
        try w.print(
            \\<p>Next update in <time datetime="{s}">{s}</time></p>
        , .{ timestampToString(&date_buf, ts), try relative_time_from_seconds(&relative_buf, utc_sec)});
    } else {
        try w.writeAll(
            \\<p>Next update unknown</p>
        );
    }


    const query_kv = try req.query();
    if (query_kv.get("success")) |_| {
        try w.writeAll("<p>Feed changes saved</p>");
    }

    if (query_kv.get("error")) |error_value| {
        if (mem.eql(u8, "delete", error_value)) {
            try w.writeAll("<p>Failed to delete feed</p>");
        } else {
            try w.writeAll("<p>Failed to save feed changes</p>");
            // TODO: list errors?
            // TODO: show errors near input fields?
        }
    }
    
    try w.writeAll("<h2>Edit feed</h2>");
    try w.writeAll("<form class='flow' style='--flow-space: var(--space-m)' method='POST'>");

    const inputs_fmt = 
    \\<div>
    \\  <p><label for="title">Feed title</label></p>
    \\  <input type="text" id="title" name="title" value="{[title]s}">
    \\</div>
    \\<div>
    \\  <p><label for="page_url">Page url</label></p>
    \\  <input type="text" id="page_url" name="page_url" value="{[page_url]s}">
    \\</div>
    \\<div>
    \\  <p><label for="icon_url">Icon url</label></p>
    \\  <input type="text" id="icon_url" name="icon_url" value="{[icon_url]s}">
    \\</div>
    ;
    try w.print(inputs_fmt, .{
        .title = feed.title, 
        .page_url = feed.page_url orelse "",
        .icon_url = feed.icon_url orelse "",
    });

    try w.writeAll("<fieldset>");
    try w.writeAll("<legend>Tags</legend>");
    try w.writeAll("<div>");
    for (tags_all, 0..) |tag, i| {
        const is_checked = blk: {
            for (feed_tags) |f_tag| {
                if (mem.eql(u8, tag, f_tag)) {
                    break :blk "checked";
                }
            }
            break :blk "";
        };
        try tag_input_render(w, .{
            .tag = tag,
            .tag_index = i,
            .is_checked = is_checked,
            .prefix = "tag-edit-",
        });
    }
    try w.writeAll("</div>");
    try w.writeAll("</fieldset>");
    try w.writeAll(
        \\<div class="form-input">
        \\  <p><label for="new_tags">New tags</label></p>
        \\  <p class="input-desc">Tags are comma separated</p>
        \\  <input type="text" id="new_tags" name="new_tags">
        \\</div>
    );

    try w.writeAll("<button class='btn btn-primary'>Save feed changes</button>");
    try w.writeAll("</form>");

    var path = req.url.path;
    if (path[path.len - 1] == '/') {
        path = path[0.. path.len - 1];
    }
    try w.print("<form action='{s}/delete' method='POST'>", .{path});
    try w.writeAll("<button class='btn btn-secondary'>Delete feed</button>");
    try w.writeAll("</form>");
    try w.writeAll("</div>");

    try w.writeAll("<h2>Feed items</h2>");
    try w.writeAll("<ul class='feed-item-list flow' style='--flow-space: var(--space-m)'>");
    for (items) |item| {
        try w.print("<li class='feed-item {s}'>", .{""});
        try item_render(w, req.arena, item);
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>");

    try w.writeAll("</main>");
    try w.writeAll(foot);
}

fn relative_time_from_seconds(buf: []u8,  seconds: i64) ![]const u8 {
    // TODO: 1 and more outputs (1 minute, 34 minutes)
    if (seconds < 0) {
        return try std.fmt.bufPrint(buf, "0 seconds", .{});
    } else if (seconds == 0) {
        return try std.fmt.bufPrint(buf, "1 second", .{});
    } else if (seconds < std.time.s_per_min) {
        return try std.fmt.bufPrint(buf, "{d} seconds", .{seconds});
    } else if (seconds < std.time.s_per_hour) {
        return try std.fmt.bufPrint(buf, "{d} minutes", .{@divFloor(seconds, std.time.s_per_min)});
    } else if (seconds < std.time.s_per_day) {
        return try std.fmt.bufPrint(buf, "{d} hours", .{@divFloor(seconds, std.time.s_per_hour)});
    } else if (seconds < std.time.s_per_week) {
        return try std.fmt.bufPrint(buf, "{d} days", .{@divFloor(seconds, std.time.s_per_day)});
    }

    return try std.fmt.bufPrint(buf, "{d} weeks", .{@divFloor(seconds, std.time.s_per_week)});
}


fn get_file(allocator: std.mem.Allocator, comptime path: []const u8) ![]const u8 {
    const builtin = @import("builtin");
    if (builtin.mode == .Debug) {
        var buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "src/{s}", .{path});
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    } else {
        return @embedFile(path);
    }
}

fn public_get(_: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    var src: ?[]const u8 = null;
    if (mem.endsWith(u8, req.url.path, "main.js")) {
        src = try get_file(req.arena, "server/main.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "style.css")) {
        src = try get_file(req.arena, "server/style.css");
        resp.content_type = .CSS;
    } else if (mem.endsWith(u8, req.url.path, "open-props-colors.css")) {
        src = try get_file(req.arena, "server/open-props-colors.css");
        resp.content_type = .CSS;
    }

    if (src) |body| {
        var al = std.ArrayList(u8).init(req.arena);
        var fbs = std.io.fixedBufferStream(body);
        try std.compress.gzip.compress(fbs.reader(), al.writer(), .{});
        resp.header("content-encoding", "gzip");
        resp.body = al.items;
    }
}

fn favicon_get(_: *Global, _: *httpz.Request, resp: *httpz.Response) !void {
    resp.status = 404;
    // resp.content_type = .ICO;
    // resp.body = @embedFile("server/favicon.ico");
}

fn latest_added_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;
    resp.content_type = .HTML;

    const w = resp.writer(); 
    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    try body_head_render(req, db, w, .{});

    try w.writeAll("<main class='content-latest'>");

    const query = try req.query();
    if (query.get("msg")) |value| {
        if (mem.eql(u8, "delete", value)) {
            try w.writeAll(
                \\<div class='message'>
                \\<p>Feed deleted</p>
                \\<a href='/'>Close message</a>
                \\</div>
            );
        }
    }

    try w.writeAll("<div class='root-heading'>");
    try w.writeAll("<h2>Latest (added)</h2>");

    const CountdownDisplay = struct {
        countdown: i64,

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            // NOTE: Might change in the future
            std.debug.assert(self.countdown > 0);
            const ct = self.countdown;
            if (ct <= 60) {
                try writer.print("{d} second", .{ct});
                if (ct > 1) {
                    try writer.writeAll("s");
                }
            } else {
                const minutes = @divTrunc(ct, 60);
                const hours = @divTrunc(ct, 3600);
                if (hours > 0) {
                    try writer.print("{d} hour", .{hours});
                    if (hours > 1 ) { try writer.writeAll("s"); }
                } else {
                    try writer.print("{d} minute", .{minutes});
                    if (minutes > 1 ) { try writer.writeAll("s"); }
                }
            }
        }
    };
    if (try db.next_update_countdown()) |countdown| {
        if (countdown > 0) {
            const countdown_ts = std.time.timestamp() + countdown;
            var date = Datetime.fromSeconds(@floatFromInt(countdown_ts));
            date = date.shiftTimezone(&@import("zig-datetime").timezones.Etc.GMTm3);

            try w.print("<span>Next update in {} ({d:0>2}:{d:0>2} {d:0>2}.{d:0>2}.{d:0>4})</span>", .{
                CountdownDisplay{.countdown = countdown},
                date.time.hour,
                date.time.minute,
                date.date.day,
                date.date.month,
                date.date.year,
            });
        } else if (countdown <= 0) {
            try w.writeAll("<span>Updating now</span>");
        }
    }
    try w.writeAll("</div>");
    
    const items = try db.get_items_latest_added(req.arena);
    if (items.len > 0) {
        var ids_al = try std.ArrayList(usize).initCapacity(req.arena, items.len);
        defer ids_al.deinit();
        for (items) |item| { ids_al.appendAssumeCapacity(item.feed_id); }
        const feeds = try db.get_feeds_with_ids(req.arena, ids_al.items);
        try w.writeAll("<ul class='feed-item-list flow' style='--flow-space: var(--space-s)'>");
        for (items) |item| {
            try w.writeAll("<li class='feed-item'>");
            const feed = blk: {
                for (feeds) |feed| {
                    if (feed.feed_id == item.feed_id) {
                        break :blk feed;
                    }
                }
                unreachable;
            };
            try item_latest_render(w, req.arena, item, feed);
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");
    } else {
        try w.writeAll("<p>No feeds have been added in the previous 3 days</p>");
    }
    try w.writeAll("</main>");

    try w.writeAll(foot);
}

fn item_latest_render(w: anytype, allocator: std.mem.Allocator, item: FeedItemRender, feed: types.Feed) !void {
    try item_render(w, allocator, item);

    const url = try std.Uri.parse(feed.page_url orelse feed.feed_url);
    const title = feed.title orelse "";
    try w.print(
        \\<div class="item-extra">
        \\<a href="/feed/{d}" class="truncate-1" title="{s}">{s}</a>
        \\<span class="feed-external-url">
    , .{ feed.feed_id, title, title });

    if (feed.icon_url) |icon_url| {
        try w.print(
            \\<img class="feed-icon" src="{s}" alt="" aria-hidden="true">
        , .{icon_url});
    }

    try w.print(
        \\<a href="{}">{+}</a>
        \\</span>
        \\</div>
    , .{ url, url });
}

fn timestamp_render(w: anytype, timestamp: ?i64) !void {
    if (timestamp) |ts| {
        var date_display_buf: [16]u8 = undefined;
        var date_buf: [date_len_max]u8 = undefined;

        const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
        const date_display_value = try date_display(&date_display_buf, now_sec, ts);
        const time_fmt = 
            \\<time class="{[age_class]s}" datetime="{[date]s}">{[date_display]s}</time>
        ;
        const age_class = age_class_from_time(ts);
        try w.print(time_fmt, .{
            .date = timestampToString(&date_buf, ts),
            .date_display = date_display_value,
            .age_class = age_class,
        });
    } else {
        const no_date_fmt = 
            \\<span class="no-date">&#8212;</span>
        ;
        try w.print(no_date_fmt, .{});
    }
}

fn tags_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;
    resp.content_type = .HTML;

    const w = resp.writer(); 
    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    try body_head_render(req, db, w, .{});

    const tags = try db.tags_all_with_ids(req.arena);
    try w.writeAll("<div>");
    try w.writeAll("<h2>Tags</h2>");
    try w.writeAll("<ul role='list'>");
    for (tags) |tag| {
        try w.writeAll("<li>");
        try w.print("{d} - ", .{tag.tag_id});
        try tag_link_print(w, tag.name);
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>");
    try w.writeAll("</div>");

    try w.writeAll(foot);
}

// TODO: try to split base to head and foot during comptime
const base_layout = @embedFile("./layouts/base.html");

fn feeds_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    resp.content_type = .HTML;

    const w = resp.writer(); 
    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    const query = try req.query();
    const search_value = query.get("search");

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

    const has_untagged = query.get("untagged") != null;
    try body_head_render(req, db, w, .{ 
        .search = search_value orelse "", 
        .tags_checked = tags_active.items, 
        .has_untagged = has_untagged,
    });

    const before = before: {
        if (query.get("before")) |value| {
            const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                break :before std.fmt.parseInt(usize, trimmed, 10) catch null;
            }
        }
        break :before null;
    };

    const is_tags_only = query.get("tags-only") != null;
    const feed_search_value = trimmed: {
        if (!is_tags_only) {
            if (search_value) |term| {
                const val = std.mem.trim(u8, term, &std.ascii.whitespace);
                if (val.len > 0) {
                    break :trimmed val;
                }
            }
        }
        break :trimmed null;
    };
    
    const feeds = blk: {
        const after = after: {
            if (before == null) {
                if (query.get("after")) |value| {
                    const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                    if (trimmed.len > 0) {
                        break :after std.fmt.parseInt(usize, trimmed, 10) catch null;
                    }
                }
            }
            break :after null;
        };

        break :blk try db.feeds_search_complex(req.arena, .{ 
            .search = search_value, 
            .tags = tags_active.items, 
            .before = before,
            .after = after, 
            .has_untagged = has_untagged,
        });
    };

    try w.writeAll("<main>");

    try w.writeAll(
        \\<header class="main-header">
        \\  <button class="js-expand-all">Expand all</button>
        \\  <button class="js-collapse-all">Collapse all</button>
        \\</header>
    );
    if (feeds.len > 0) {
        try feeds_and_items_print(w, req.arena, db, feeds);
        if (feeds.len == config.query_feed_limit) {
            var new_url_arr = try std.ArrayList(u8).initCapacity(req.arena, 128);
            defer new_url_arr.deinit();
            new_url_arr.appendSliceAssumeCapacity("/feeds?");
            for (query.keys[0..query.len], query.values[0..query.len]) |key, value| {
                if (mem.eql(u8, "after", key)) {
                    continue;
                }
                try new_url_arr.appendSlice(key);
                try new_url_arr.append('=');
                try new_url_arr.appendSlice(value);
                try new_url_arr.append('&');
            }
            const current_path_len = new_url_arr.items.len;

            try w.writeAll("<footer class='main-footer'>");

            const has_prev = try db.feeds_search_has_previous(req.arena, .{ 
                .search = feed_search_value, 
                .tags = tags_active.items, 
                .before = feeds[0].feed_id,
                .after = null, 
                .has_untagged = has_untagged,
            });
            if (has_prev) {
                const href_prev = blk: {
                    try new_url_arr.appendSlice("before");
                    try new_url_arr.append('=');
                    const id_first = feeds[0].feed_id;
                    try new_url_arr.writer().print("{d}", .{id_first});

                    break :blk new_url_arr.items;
                };

                try w.print("<a href=\"{s}\">Previous</a>", .{href_prev});
            }

            // This is a little bit naughty
            // reusing memory that was used by 'href_prev'
            new_url_arr.items.len = current_path_len;
            const href_next = blk: {
                try new_url_arr.appendSlice("after");
                try new_url_arr.append('=');
                const id_last = feeds[feeds.len - 1].feed_id;
                try new_url_arr.writer().print("{d}", .{id_last});

                break :blk new_url_arr.items;
            };
            try w.print("<a href=\"{s}\">Next</a>", .{href_next});

            try w.writeAll("</footer>");
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
    try w.writeAll("<div>");
    for (feeds) |feed| {
        try w.writeAll("<article class='feed'>");
        try w.writeAll("<header class='feed-header'>");

        try w.writeAll("<div class='icon-wrapper'>");
        if (feed.icon_url) |icon_url| {
            try w.print("<img class='feed-icon' src='{s}'>", .{icon_url});
        }
        try w.writeAll("</div>");

        try w.writeAll("<div class='feed-and-tags'>");
        try w.writeAll("<div class='feed-header-top'>");
        try feed_render(w, feed);
        try feed_edit_link_render(w, feed.feed_id);
        try w.writeAll("</div>");

        const tags = try db.feed_tags(allocator, feed.feed_id);
        if (tags.len > 0) {
            try w.writeAll("<div class='feed-tags'>");
            for (tags) |tag| {
                try tag_link_print(w, tag);
            }
            try w.writeAll("</div>");
        }
        try w.writeAll("</div>");
        try w.writeAll("</header>");
        
        const items = try db.feed_items_with_feed_id(allocator, feed.feed_id);
        if (items.len == 0) {
            continue;
        }

        const date_in_sec: i64 = @intFromFloat(Datetime.now().toSeconds());

        var hide_index_start: ?usize = null;
        const age_1day_ago = date_in_sec - std.time.s_per_day;

        for (items[1..], 1..) |item, i| {
            if (item.created_timestamp < age_1day_ago) {
                hide_index_start = i - 1;
                break;
            }
        }

        try w.writeAll("<ul class='feed-item-list flow' style='--flow-space: var(--space-m)'>");
        for (items, 0..) |item, i| {
            const hidden: []const u8 = blk: {
                if (hide_index_start) |index| {
                    if (index == i) {
                        break :blk "hide-after";
                    }
                }
                break :blk "";
            };

            try w.print("<li class='feed-item {s}'>", .{hidden});
            try item_render(w, allocator, item);
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");
        const aria_expanded = if (hide_index_start != null) "false" else "true";
        try w.print(
            \\<footer class="feed-footer">
            \\  <button class="js-feed-item-toggle feed-item-toggle" aria-expanded="{s}">
            \\    <span class="toggle-expand">Expand</span>
            \\    <span class="toggle-collapse">Collapse</span>
            \\</button>
            \\</footer>
        , .{aria_expanded});

        try w.writeAll("</article>");
    }
    try w.writeAll("</div>");
}

fn age_class_from_time(time: ?i64) []const u8 {
    const date_in_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
    const age_3days_ago = date_in_sec - (std.time.s_per_day * 3);
    const age_30days_ago = date_in_sec - (std.time.s_per_day * 30);
            
    if (time) |updated_timestamp| {
        // TODO: date might be in the future?
        if (updated_timestamp > age_3days_ago) {
            return "age-newest";
        } else if (updated_timestamp <= age_3days_ago and updated_timestamp >= age_30days_ago) {
            return "age-less-month";
        } else if (updated_timestamp < age_30days_ago) {
            return "age-more-month";
        }
    }
    return "";
}

fn feed_edit_link_render(w: anytype, feed_id: usize) !void {
    const edit_fmt = 
    \\<a class="feed-edit" href="/feed/{d}">Edit feed</a>
    ;
    try w.print(edit_fmt, .{ feed_id });
}

fn item_render(w: anytype, allocator: std.mem.Allocator, item: FeedItemRender) !void {
    try timestamp_render(w, item.updated_timestamp);

    const item_title = if (item.title.len > 0) try html.encode(allocator, item.title) else title_placeholder;

    if (item.link) |link| {
        const item_link_fmt =
            \\<a href="{[link]s}" class="item-link truncate-2" title="{[title]s}">{[title]s}</a>
        ;
        try w.print(item_link_fmt, .{ .title = item_title, .link = link });
    } else {
        const item_title_fmt =
            \\<p class="truncate-2" title="{[title]s}">{[title]s}</p>
        ;
        try w.print(item_title_fmt, .{ .title = item_title });
    }
}

fn feed_render(w: anytype, feed: types.FeedRender) !void {
    const title = if (feed.title.len > 0) feed.title else title_placeholder;

    if (feed.page_url) |page_url| {
        const feed_link_fmt = 
        \\<a class="feed-title truncate-1" href="{[page_url]s}">{[title]s}</a>
        ;
        try w.print(feed_link_fmt, .{ .page_url = page_url, .title = title });
    } else {
        const feed_title_fmt =
        \\<p class="feed-title truncate-1">{[title]s}</p>
        ;
        try w.print(feed_title_fmt, .{ .title = title });
    }

    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());
    var date_display_buf: [16]u8 = undefined;
    var date_buf: [date_len_max]u8 = undefined;

    const age_class = age_class_from_time(feed.updated_timestamp);
    const date_display_val = if (feed.updated_timestamp) |ts| try date_display(&date_display_buf, now_sec, ts) else "";

    try w.print( 
        \\<time class="{[age_class]s}" datetime="{[date]s}">{[date_display]s}</time>
    , .{
        .age_class = age_class,
        .date = timestampToString(&date_buf, feed.updated_timestamp),
        .date_display = date_display_val,
    });
}

const HeadOptions = struct {
    search: []const u8 = "",
    tags_checked: [][]const u8 = &.{},
    has_untagged: bool = false,
};

fn nav_link_render(path: []const u8, name: []const u8, w: anytype, curr_path: []const u8) !void {
    if (mem.eql(u8, path, curr_path)) {
        const fmt = 
        \\<a href="{s}" aria-current="page">{s}</a>
        ;
        try w.print(fmt, .{path, name});
    } else {
        const fmt = 
        \\<a href="{s}">{s}</a>
        ;
        try w.print(fmt, .{path, name});
    }
}

fn body_head_render(req: *httpz.Request, db: *Storage, w: anytype, opts: HeadOptions) !void {
    const allocator = req.arena;
    try w.writeAll("<header class='body-header flow'>");

    try w.writeAll("<div>");
    try w.writeAll("<h1 class='sidebar-heading'>feedgaze</h1>");
    try w.writeAll("<nav>");
    try nav_link_render("/", "Home", w, req.url.path);
    try w.writeAll("<span>|</span>");
    try nav_link_render("/feeds", "Feeds", w, req.url.path);
    try w.writeAll("<span>|</span>");
    try nav_link_render("/tags", "Tags", w, req.url.path);
    try w.writeAll("</nav>");
    try w.writeAll("</div>");

    try w.writeAll("<div class='filter-wrapper'>");
    try w.writeAll("<h2 class='sidebar-heading'>Filter feeds</h2>");
    const tags = try db.tags_all(allocator);
    try w.writeAll("<form action='/feeds'>");
    // NOTE: don't want tags-only button to be the 'default' button. This is
    // used when enter is pressed in input (text) field.
    try w.writeAll(
    \\<button aria-hidden="true" style="display: none">Default form action</button>
    );
    try w.writeAll("<fieldset class='tags flow' style='--flow-space: var(--space-2xs)'>");
    try w.writeAll("<legend class='visually-hidden'>Tags</legend>");
    try w.writeAll("<h3 class='form-heading' aria-hidden='true'>Tags</h3>");

    try untagged_label_render(w, opts.has_untagged);

    for (tags, 0..) |tag, i| {
        try tag_label_render(w, tag, i + 1, opts.tags_checked);
    }
    try w.writeAll("</fieldset>");
    try w.writeAll("<button name='tags-only'>Filter tags only</button>");

    try w.print(
    \\<p>
    \\  <label class="form-heading" for="search_value">Filter term</label>
    \\  <input type="search" name="search" id="search_value" value="{s}">
    \\  <button class="form-submit">Filter</button>
    \\</p>
    , .{ opts.search });

    try w.writeAll("</form>");
    try w.writeAll("</div>");
    try w.writeAll("</header>");
}

fn untagged_label_render(w: anytype, has_untagged: bool) !void {
    try w.writeAll("<div class='tag'>");
    const is_checked: []const u8 = if (has_untagged) "checked" else "";
    const tag_fmt = 
    \\<span class="tag-checkbox">
    \\<input type="checkbox" name="untagged" id="untagged" {[is_checked]s}>
    \\<label class="visually-hidden" for="untagged">{[value]s}</label>
    \\</span>
    ;
    try w.print(tag_fmt, .{ .value = untagged, .is_checked = is_checked });
    try w.print("<a href='/?untagged='>{s}</a>", .{ untagged });
    try w.writeAll("</div>");
}

fn tag_label_render(w: anytype, tag: []const u8, index: usize, tags_checked: [][]const u8) !void {
    try w.writeAll("<div class='tag'>");
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
        .label_class = "visually-hidden",
    });
    try tag_link_print(w, tag);
    try w.writeAll("</div>");
}

const InputRenderArgs = struct{
    tag: []const u8, 
    tag_index: usize, 
    is_checked: []const u8,
    prefix: []const u8 = "tag-id-",
    label_class: []const u8 = &.{},
};

fn tag_input_render(w: anytype, args: InputRenderArgs) !void {
    const tag_fmt = 
    \\<span class="tag-checkbox">
    \\<input type="checkbox" name="tag" id="{[prefix]s}{[tag_index]d}" value="{[tag]s}" {[is_checked]s}>
    \\<label class="{[label_class]s}" for="{[prefix]s}{[tag_index]d}">{[tag]s}</label>
    \\</span>
    ;
    try w.print(tag_fmt, args);
}

fn tag_link_print(w: anytype, tag: []const u8) !void {
    const tag_link_fmt = 
    \\<a href="/feeds?tag={[tag]s}">{[tag]s}</a>
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
const html = @import("./html.zig");
