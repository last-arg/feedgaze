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
    std.debug.print("RUN SERVER\n", .{});
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
    tk.get("/", root_handler),
    tk.get("/style.css", tk.sendStatic("./src/style.css")),
    tk.group("/feeds", tk.router(feeds_path)),
    tk.get("/tags", tags_handler),
    not_found,
});

fn not_found(ctx: *tk.Context) !void {
    try ctx.res.setHeader("content-type", "text/html");
    try ctx.res.notFound();
    try ctx.res.send(@as([]const u8, @embedFile("./not_found.html")));
}

const feeds_path = struct {
    pub fn @"GET /"(ctx: *tk.Context, req: *tk.Request, resp: *tk.Response) !void {
        const db = try ctx.injector.get(*Storage);

        var query_map = Query.init(req.allocator);
        defer query_map.deinit();
        if (req.url.query) |query| {
            try query_map.parse(query);
        }

        try resp.setHeader("content-type", "text/html");

        const w = try resp.writer(); 
        var base_iter = mem.splitSequence(u8, base_layout, "[content]");
        const head = base_iter.next() orelse unreachable;
        const foot = base_iter.next() orelse unreachable;

        try w.writeAll(head);

        const search_value = blk: {
            if (query_map.get_value("search")) |value| {
                const dupe = try req.allocator.dupe(u8, value);
                mem.replaceScalar(u8, dupe, '+', ' ');
                break :blk try std.Uri.unescapeString(req.allocator, dupe);
            }
            break :blk null;
        };
        defer if (search_value) |v| req.allocator.free(v);

        const tags_count = query_map.key_count("tag");
        var tags_active = try std.ArrayList([]const u8).initCapacity(req.allocator, tags_count);
        defer tags_active.deinit();

        var tag_iter = query_map.values_iter("tag");
        while (tag_iter.next()) |value| {
            const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const tag = try std.Uri.unescapeString(req.allocator, trimmed);
                tags_active.appendAssumeCapacity(tag);
            }
        }

        try body_head_render(req.allocator, db, w, search_value orelse "", tags_active.items);

        const feeds = blk: {
            const after = after: {
                if (query_map.get_value("after")) |value| {
                    const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                    if (trimmed.len > 0) {
                        break :after std.fmt.parseInt(usize, trimmed, 10) catch null;
                    }
                }
                break :after null;
            };

            const is_tags_only = query_map.has("tags-only");
            if (tags_active.items.len > 0) {
                if (!is_tags_only and search_value != null and search_value.?.len > 0) {
                    const value = search_value.?;
                    break :blk try db.feeds_search_with_tags(req.allocator, value, tags_active.items, after);
                } else {
                    break :blk try db.feeds_with_tags(req.allocator, tags_active.items, after);
                }
            }

            if (!is_tags_only) {
                if (search_value) |term| {
                    const trimmed = std.mem.trim(u8, term, &std.ascii.whitespace);
                    if (trimmed.len > 0) {
                        break :blk try db.feeds_search(req.allocator, trimmed, after);
                    }
                }
            }

            break :blk try db.feeds_page(req.allocator, after);
        };

        try feeds_and_items_print(w, req.allocator, db, feeds);
        if (feeds.len > 0) {
            if (feeds.len == config.query_feed_limit) {
                const href = blk: {
                    const id_new = feeds[feeds.len - 1].feed_id;
                    if (req.url.query) |q| {
                        if (query_map.get_value("after")) |id_curr| {
                            var buf_needle: [32]u8 = undefined;
                            const needle = try std.fmt.bufPrint(&buf_needle, "after={s}", .{id_curr});
                            var buf_replace: [32]u8 = undefined;
                            const replace = try std.fmt.bufPrint(&buf_replace, "after={d}", .{id_new});
                            const query_new = try std.mem.replaceOwned(u8, req.allocator, q, needle, replace);
                            break :blk try std.fmt.allocPrint(req.allocator, "?{s}", .{query_new});
                        } else if (q.len > 0) {
                            break :blk try std.fmt.allocPrint(req.allocator, "?{s}&after={d}", .{q, id_new});
                        }
                    }
                    break :blk try std.fmt.allocPrint(req.allocator, "?after={d}", .{id_new});
                };
                try w.print(
                    \\<a href="{s}">Next</a>
                , .{href});
            }
        } else {
            try w.writeAll(
                \\<p>Nothing more to show</p>
            );
        }

        try w.writeAll(foot);
    }

    pub fn @"GET /:id"(ctx: *tk.Context, req: *tk.Request, resp: *tk.Response, id_raw: []const u8) !void {
        const feed_id = try std.fmt.parseInt(usize, id_raw, 10);
        const db = try ctx.injector.get(*Storage);
        const feed_result = try db.feed_with_id(req.allocator, feed_id);
        if (feed_result == null) {
            try not_found(ctx);
            return;
        }

        const feed = feed_result.?;
        const tags_all = try db.tags_all(req.allocator);
        const feed_tags = try db.feed_tags(req.allocator, feed.feed_id);
        const items = try db.feed_items_with_feed_id(req.allocator, feed.feed_id);

        try resp.setHeader("content-type", "text/html");
        const w = try resp.writer(); 
        var base_iter = mem.splitSequence(u8, base_layout, "[content]");
        const head = base_iter.next() orelse unreachable;
        const foot = base_iter.next() orelse unreachable;

        try w.writeAll(head);

        try body_head_render(req.allocator, db, w, "", &.{});

        try w.writeAll("<h2>Edit feed</h2>");
        try w.print(
            \\<p>Feed url: <a href="">{[feed_url]s}</a></p>
        , .{ .feed_url = feed.feed_url });
        try w.writeAll("<form method='POST'>");
        // TODO: render feed edit stuff
        // title
        // feed_url - can't edit?
        // page_url - might get overwritten during update 

        const inputs_fmt = 
        \\<input type="hidden" name="feed_id" value="{[feed_id]d}">
        \\<label for="title">Feed title</label>
        \\<input type="text" id="title" name="title" value="{[title]s}">
        \\<label for="page_url">Page url</label>
        \\<input type="text" id="page_url" name="page_url" value="{[page_url]s}">
        \\<a href="{[page_url]s}">Go to page url</a>
        ;
        try w.print(inputs_fmt, .{
            .title = feed.title, 
            .feed_id = feed.feed_id,
            .page_url = feed.page_url orelse "",
        });

        // TODO: feed updating
        // - update feed now?
        //   - show time till next update?
        // - allow changing update interval?

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
        try w.writeAll("<button>Save feed changes</button>");
        try w.writeAll("</form>");

        try w.writeAll("<ul>");
        for (items) |item| {
            try w.writeAll("<li>");
            try item_render(w, item);
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");

        try w.writeAll(foot);
    }

    // TODO: implement Cookies and Session
    pub fn @"POST /:id"(ctx: *tk.Context, req: *tk.Request, resp: *tk.Response, id: usize, _: void) !void {
        const db = try ctx.injector.get(*Storage);
        std.debug.print("id: {d}\n", .{id});

        const reader = try req.raw.reader();
        const body = try reader.readAllAlloc(req.allocator, std.math.maxInt(u32));
        var q = Query.init(req.allocator);
        defer q.deinit();
        try q.parse(body);
        
        std.debug.print("url: {}\n", .{ctx.req.url});
        std.debug.print("\n{}\n", .{q});
        if (!try db.hasFeedWithId(id)) {
            try not_found(ctx);
            return;
        }

        resp.status = .see_other;

        const url_success = try std.fmt.allocPrint(req.allocator, "/feeds/{d}?success=", .{id});
        try resp.setHeader("Location", url_success);
        try resp.respond();
        // TODO:
        // decode and validate form data
        // update feed
        // update feed tags
        // - remove tags aren't part of feed 
        // - add tags to make sure every tag exists

        const tags_count = q.key_count("tag");
        var tags_active = try std.ArrayList([]const u8).initCapacity(req.allocator, tags_count);
        defer tags_active.deinit();

        var tag_iter = q.values_iter("tag");
        while (tag_iter.next()) |value| {
            const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const tag = try std.Uri.unescapeString(req.allocator, trimmed);
                tags_active.appendAssumeCapacity(tag);
            }
        }

        try db.tags_remove_keep(req.allocator, id, tags_active.items);
        // db.tags_all();
    }
    

    // pub fn @"GET *"(ctx: *tk.Context) !void {
    //     try not_found(ctx);
    // }
};

fn tags_handler(ctx: *tk.Context, req: *tk.Request, resp: *tk.Response) !void {
    const db = try ctx.injector.get(*Storage);
    try resp.setHeader("content-type", "text/html");

    const w = try resp.writer(); 
    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    try body_head_render(req.allocator, db, w, "", &.{});

    const tags = try db.tags_all_with_ids(req.allocator);
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



const Query = struct {
    allocator: std.mem.Allocator,
    keys: ArraySlice,
    values: ArraySlice,

    const ArraySlice = std.ArrayList([]const u8);

    pub fn init(allocator: std.mem.Allocator) Query {
        return .{
            .allocator = allocator,
            .keys = ArraySlice.init(allocator),
            .values = ArraySlice.init(allocator),
        };
    }

    pub fn parse(self: *Query, input: []const u8) !void {
        // Being a little naughty
        const query: []u8 = @constCast(input);
        mem.replaceScalar(u8, query, '+', ' ');

        const count_max = mem.count(u8, query, "&") + 1;
        try self.keys.ensureTotalCapacityPrecise(count_max);
        try self.values.ensureTotalCapacityPrecise(count_max);

        var iter = mem.splitScalar(u8, query, '&');
        while (iter.next()) |kv| {
            var kv_iter = mem.splitScalar(u8, kv, '=');
            const key = kv_iter.next() orelse return error.InvalidQueryParamKey;
            const value = kv_iter.next() orelse return error.InvalidQueryParamValue;
            std.debug.assert(kv_iter.next() == null);
            self.keys.appendAssumeCapacity(key);
            self.values.appendAssumeCapacity(value);
        }
        std.debug.assert(self.keys.items.len == self.values.items.len);
    }

    pub fn key_count(self: Query, key: []const u8) usize {
        var iter = self.values_iter(key);
        var count: usize = 0;
        while (iter.next()) |_| : (count += 1){}
        return count;
    }

    // stored keys and value will be encoded
    pub fn get_value(self: Query, key: []const u8) ?[]const u8 {
        // TODO: encode input key?
        for (self.keys.items, 0..) |key_item, i| {
            if (mem.eql(u8, key, key_item)) {
                return self.values.items[i];
            }
        }
        return null;
    }

    pub fn has(self: Query, key: []const u8) bool {
        return self.get_value(key) != null;
    }

    const QueryIter = struct {
            query: Query,  
            key_search: []const u8,
            index: usize = 0,
            pub fn next(self: *@This()) ?[]const u8 {
                if (self.index < self.query.keys.items.len) {
                    for (self.index..self.query.keys.items.len) |i| {
                        const key = self.query.keys.items[i];
                        if (mem.eql(u8, key, self.key_search)) {
                            self.index = i + 1;
                            return self.query.values.items[i];
                        }
                    }
                }
                return null;
            }
        };

    pub fn values_iter(query: Query, key: []const u8) QueryIter {
        return .{.query = query, .key_search = key };
    }

    pub fn format(self: *const Query, comptime _: []const u8, _: anytype, writer: anytype) !void {
        try writer.writeAll("=== Query keys and values ===\n");
        for (self.keys.items, 0..) |key, i| {
            const value = self.values.items[i];
            try writer.print("{s}: {s}\n", .{key, value});
        }
    }

    pub fn deinit(self: *Query) void {
        self.keys.deinit();
        self.values.deinit();
    }
};

fn feed_edit_link_render(w: anytype, feed_id: usize) !void {
    const edit_fmt = 
    \\<a href="/feeds/{d}">Edit feed</a>
    ;
    try w.print(edit_fmt, .{ feed_id });
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
}

const base_layout = @embedFile("./layouts/base.html");

fn get_search_value(input: []const u8) !?[]const u8 {
    var iter = mem.splitSequence(u8, input, "&");
    while (iter.next()) |kv| {
        var kv_iter = mem.splitSequence(u8, kv, "=");
        const key = kv_iter.next() orelse break;
        if (mem.eql(u8, key, "search")) {
            return mem.trim(u8, kv_iter.next() orelse "", &std.ascii.whitespace);
        }
    }
    return null;
}

// TODO: remove most of this
// - make /feeds -> /
// - redirect / -> /feeds
pub fn root_handler(ctx: *tk.Context, req: *tk.Request, resp: *tk.Response) !void {
    const search_value = blk: {
        if (req.url.query) |query_raw| {
            const query = try std.Uri.unescapeString(req.allocator, query_raw);
            break :blk try get_search_value(query);
        }
        break :blk null;
    };

    if (search_value != null and search_value.?.len == 0) {
        resp.status = .permanent_redirect;
        try resp.setHeader("location", "/");
        try resp.respond();
        return;
    }

    const db = try ctx.injector.get(*Storage);
    try resp.setHeader("content-type", "text/html");
    const w = try resp.writer(); 
    var base_iter = mem.splitSequence(u8, base_layout, "[content]");
    const head = base_iter.next() orelse unreachable;
    const foot = base_iter.next() orelse unreachable;

    try w.writeAll(head);

    try body_head_render(req.allocator, db, w, search_value orelse "", &.{});

    const feeds = blk: {
        if (search_value) |term| {
            const trimmed = std.mem.trim(u8, term, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                break :blk try db.feeds_search(req.allocator, trimmed, null);
            }
        }
        break :blk try db.feeds_all(req.allocator);
    };
    
    try feeds_and_items_print(w, req.allocator, db, feeds);

    try w.writeAll(foot);
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

fn tag_link_print(w: anytype, tag: []const u8) !void {
    const tag_link_fmt = 
    \\<a href="/feeds?tag={[tag]s}">{[tag]s}</a>
    ;
    
    try w.print(tag_link_fmt, .{ .tag = tag });
}

fn body_head_render(allocator: std.mem.Allocator, db: *Storage, w: anytype, search_value: []const u8, tags_checked: [][]const u8,) !void {
    try w.writeAll("<header>");
    try w.writeAll("<h1>feedgaze</h1>");
    try w.writeAll(
      \\<a href="/">Home</a>
      \\<a href="/feeds">Feeds</a>
      \\<a href="/tags">Tags</a>
    );

    const tags = try db.tags_all(allocator);
    try w.writeAll("<form action='/feeds'>");
    // This makes is the default action of form. For example used when pressing
    // enter inside input text field.
    try w.writeAll(
    \\  <button style="display: none">Default form action</button>
    );
    for (tags, 0..) |tag, i| {
        try w.writeAll("<span>");
        var is_checked: []const u8 = "";
        for (tags_checked) |tag_checked| {
            if (mem.eql(u8, tag, tag_checked)) {
                is_checked = "checked";
                break;
            }
        }
        try tag_input_render(w, .{
            .tag = tag,
            .tag_index = i,
            .is_checked = is_checked,
        });
        try tag_link_print(w, tag);
        try w.writeAll("</span>");
    }
    try w.writeAll("<button name='tags-only'>Filter tags only</button>");

    try w.print(
    \\  <label for="search_value">Search feeds</label>
    \\  <input type="search" name="search" id="search_value" value="{s}">
    \\  <button>Filter</button>
    , .{ search_value });

    try w.writeAll("</form>");
    try w.writeAll("</header>");
}

const InputRenderArgs = struct{
    tag: []const u8, 
    tag_index: usize, 
    is_checked: []const u8,
    prefix: []const u8 = "tag-id-",
};

fn tag_input_render(w: anytype, args: InputRenderArgs) !void {
    const tag_fmt = 
    \\<span>
    \\<input type="checkbox" name="tag" id="{[prefix]s}{[tag_index]d}" value="{[tag]s}" {[is_checked]s}>
    \\<label for="{[prefix]s}{[tag_index]d}">{[tag]s}</label>
    \\</span>
    ;
    try w.print(tag_fmt, args);
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
const types = @import("./feed_types.zig");
const FeedItemRender = types.FeedItemRender;
const storage = @import("./storage.zig");
const Storage = storage.Storage;
const config = @import("app_config.zig");
const Datetime = @import("zig-datetime").datetime.Datetime;
const mem = std.mem;
