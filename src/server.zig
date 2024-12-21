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

    var global: Global = .{ .storage = storage };
    const server_config: httpz.Config = .{
        .port = opts.port,  
        .request = .{
            .max_form_count = 10,
        }
    };
    var server = try httpz.Server(*Global).init(allocator, server_config, &global);
    var router = server.router(.{});

    router.get("/", latest_added_get, .{});
    router.get("/feeds", feeds_get, .{});
    router.get("/tags", tags_get, .{});
    router.get("/tag/:id/edit", tag_edit, .{});
    router.post("/tag/:id/edit", tag_edit_post, .{});
    router.get("/tag/:id/delete", tag_delete, .{});
    router.get("/feed/add", feed_add_get, .{});
    router.post("/feed/add", feed_add_post, .{});
    router.get("/feed/pick", feed_pick_get, .{});
    router.post("/feed/pick", feed_pick_post, .{});
    router.get("/feed/:id", feed_get, .{});
    router.post("/feed/:id", feed_post, .{});
    router.post("/feed/:id/delete", feed_delete, .{});
    router.get("/public/*", public_get, .{});
    router.get("/favicon.ico", favicon_get, .{});

    std.log.info("Server started at 'http://localhost:{d}'", .{opts.port});
    // start the server in the current thread, blocking.
    try server.listen(); 
}

fn write_pick_urls(writer: anytype, form_data: *httpz.key_value.StringKeyValue) !void {
    var iter = form_data.iterator();
    while (iter.next()) |kv| {
        if (mem.eql(u8, "url", kv.key)) {
            const c: std.Uri.Component = .{ .raw = mem.trim(u8, kv.value, &std.ascii.whitespace) };
            try writer.print("&url={%}", .{c});
        }
    }
}

const selector_names = .{
    "selector-container",
    "selector-link",
    "selector-heading",
    "selector-date",
    "feed-date-format",
};

fn write_selectors(writer: anytype, form_data: *httpz.key_value.StringKeyValue) !void {
    inline for (selector_names) |sel| {
        if (form_data.get(sel)) |raw| {
            const val = mem.trim(u8, raw, &std.ascii.whitespace);
            if (val.len > 0) {
                const c: std.Uri.Component = .{ .raw = val };
                try writer.print("&{s}={%}", .{sel, c});
            }
        }
    }
}

fn feed_pick_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    resp.status = 303;

    const form_data = try req.formData();

    const tags_input = blk: {
        if (form_data.get("input-tags")) |val| {
            const trimmed = mem.trim(u8, val, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                break :blk trimmed;
            }
        }
        break :blk null;
    };

    var location_arr = try std.ArrayList(u8).initCapacity(req.arena, 64);

    const url_input = mem.trim(
        u8, 
        form_data.get("input-url") orelse "", 
        &std.ascii.whitespace,
    );
    if (url_input.len == 0) {
        try location_arr.writer().writeAll("/feed/add?error=url-missing");
        if (tags_input) |val| {
            const c: std.Uri.Component = .{ .raw = val };
            try location_arr.writer().print("&input-tags={%}", .{c});
        }

        resp.header("Location", location_arr.items);
        return;
    }

    _ = std.Uri.parse(url_input) catch {
        const url_comp: std.Uri.Component = .{ .raw = url_input };
        try location_arr.writer().print("/feed/add?error=invalid-url&input-url={%}", .{url_comp});
        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try location_arr.writer().print("&input-tags={%}", .{c2});
        }

        resp.header("Location", location_arr.items);
        return;
    };

    const url_picked = mem.trim(
        u8, 
        form_data.get("url-picked") orelse "",
        &std.ascii.whitespace
    );
    if (url_picked.len == 0) {
        const url_comp: std.Uri.Component = .{ .raw = url_input };
        try location_arr.writer().print("/feed/pick?error=pick-url&input-url={%}", .{url_comp});
        if (tags_input) |val| {
            const c: std.Uri.Component = .{ .raw = val };
            try location_arr.writer().print("&input-tags={%}", .{c});
        }
        try write_pick_urls(location_arr.writer(), form_data);
        try write_selectors(location_arr.writer(), form_data);

        resp.header("Location", location_arr.items);
        return;
    }

    const is_html_feed = mem.eql(u8, "html", url_picked);

    if (!is_html_feed) {
        _ = std.Uri.parse(url_picked) catch {
            const url_comp: std.Uri.Component = .{ .raw = url_picked };
            try location_arr.writer().print("/feed/pick?error=invalid-url&input-url={%}", .{url_comp});
            if (tags_input) |val| {
                const c2: std.Uri.Component = .{ .raw = val };
                try location_arr.writer().print("&input-tags={%}", .{c2});
            }

            try write_pick_urls(location_arr.writer(), form_data);
            try write_selectors(location_arr.writer(), form_data);

            resp.header("Location", location_arr.items);
            return;
        };
    }

    const feed_url = if (is_html_feed) url_input else url_picked;

    const pick_index = blk: {
        var iter = form_data.iterator();
        var i: u32 = 0;
        while (iter.next()) |kv| {
            if (!mem.eql(u8, "url", kv.key)) { continue; }

            if (mem.eql(u8, kv.value, url_picked)) {
                break;
            }
            i += 1;
        }
        break :blk i;
    };

    if (try db.get_feed_id_with_url(feed_url)) |feed_id| {
        const url_comp: std.Uri.Component = .{ .raw = url_input };
        try location_arr.writer().print("/feed/pick?feed-exists={d}&input-url={%}", .{feed_id, url_comp});

        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try location_arr.writer().print("&input-tags={%}", .{c2});
        }

        try write_pick_urls(location_arr.writer(), form_data);
        try write_selectors(location_arr.writer(), form_data);
        try location_arr.writer().print("&pick-index={}", .{pick_index});

        resp.header("Location", location_arr.items);
        return;
    }

    const selector_container = mem.trim(
        u8, 
        form_data.get("selector-container") orelse "",
        &std.ascii.whitespace,
    );
    if (is_html_feed and selector_container.len == 0) {
        const url_comp: std.Uri.Component = .{ .raw = url_input };
        try location_arr.writer().print("/feed/pick?error=empty-selector&input-url={%}", .{url_comp});
        try write_pick_urls(location_arr.writer(), form_data);
        try write_selectors(location_arr.writer(), form_data);
        try location_arr.writer().print("&pick-index={}", .{pick_index});

        resp.header("Location", location_arr.items);
        return;
    }

    // try to add new feed
    const App = @import("app.zig").App;
    var app = App{.storage = db.*, .allocator = req.arena};

    var fetch = try app.fetch_response(req.arena, feed_url);
    defer fetch.deinit();

    const feed_options = FeedOptions.fromResponse(fetch.resp);
    var add_opts: Storage.AddOptions = .{ .feed_opts = feed_options };

    if (feed_options.content_type == .html) {
        add_opts.html_opts = .{
            .selector_container = selector_container,
            .selector_link = form_data.get("selector-link"),
            .selector_heading = form_data.get("selector-heading"),
            .selector_date = form_data.get("selector-date"),
            .date_format = form_data.get("feed-date-format"),
        };
    }

    add_opts.feed_opts.feed_url = try fetch.req.get_url_slice();
    const feed_id = try db.addFeed(req.arena, add_opts);

    if (tags_input) |raw| {
        errdefer |err| {
            std.log.err("Failed to add tags for new feed '{s}'. Error: {}", .{add_opts.feed_opts.feed_url, err});
        }

        var iter = mem.splitScalar(u8, raw, ',');
        const cap = mem.count(u8, raw, ",") + 1;
        var tags_arr = try std.ArrayList([]const u8).initCapacity(req.arena, cap);
        defer tags_arr.deinit();

        while (iter.next()) |tag| {
            const trimmed = mem.trim(u8, tag, &std.ascii.whitespace);
            tags_arr.appendAssumeCapacity(trimmed);
        }

        try db.tags_add(tags_arr.items);
        const tags_ids_buf = try req.arena.alloc(usize, tags_arr.items.len);
        const tags_ids = try db.tags_ids(tags_arr.items, tags_ids_buf);
        try db.tags_feed_add(feed_id, tags_ids);
    }

    try location_arr.writer().print("/feed/add?success={d}", .{feed_id});
    resp.header("Location", location_arr.items);
}

fn feed_pick_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    var query = try req.query();

    const url_raw = query.get("input-url") orelse {
        resp.header("Location", "/feed/add?error=url-missing");
        return;
    }; 

    const url = mem.trim(u8, url_raw, &std.ascii.whitespace);
    if (url.len == 0) {
        resp.header("Location", "/feed/add?error=url-missing");
        return;
    }
        
    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };

    try Layout.write_head(w, "Pick feed", .{});

    try body_head_render(req, db, w, .{});

    try w.writeAll("<main class='box'>");
    try w.writeAll("<h2>Add feed</h2>");

    if (query.get("feed-exists")) |raw_value| {
        const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
        if (std.fmt.parseUnsigned(usize, value, 10)) |feed_id| {
            try w.print(
                \\<p>Feed already exists.
                \\<a href="/feed/{d}">Got to feed page</a>.
                \\</p>
            , .{feed_id});
        } else |err| {
            std.log.warn("Failed to get parse feed id '{s}'. Error: {}", .{value, err});
            try w.writeAll("<p>Feed already exists.</p>");
        }
    } else if (query.get("error")) |value| {
        if (mem.eql(u8, "invalid-url", value)) {
            try w.writeAll("<p>Enter valid url.</p>");
        } else if (mem.eql(u8, "url-missing", value)) {
            try w.writeAll("<p>Pick feed option.</p>");
        } else if (mem.eql(u8, "empty-selector", value)) {
            try w.writeAll("<p>Fill in 'Feed item selector'.</p>");
        } else if (mem.eql(u8, "pick-url", value)) {
            try w.writeAll("<p>Pick on of the feed options.</p>");
        }
    }

    const url_escaped = try parse.html_escape(req.arena, url);
    try w.print("<p>Page url: {s}</p>", .{url_escaped});
    try w.writeAll(
        \\<form action="/feed/pick" method="POST" class="flow" style="--flow-space(--space-m)">
    );
    try w.print("<input type='hidden' name='input-url' value='{s}'>", .{url_escaped});

    try w.writeAll("<fieldset>");
    try w.writeAll("<legend>Pick feed to add</legend>");

    const pick_index = blk: {
        if (query.get("pick-index")) |raw| {
            break :blk std.fmt.parseInt(u32, raw, 10) catch 0;
        }
        break :blk 0;
    };

    var iter = query.iterator();
    var index: usize = 0;
    while (iter.next()) |kv| {
        if (mem.eql(u8, "url", kv.key)) {
            try w.writeAll("<p>");
            const value_escaped = try parse.html_escape(req.arena, kv.value);
            // const checked = if (pick_index == index) "checked" else "";
            const checked = "";
            try w.print(
                \\<input type="hidden" name="url" value="{[value]s}"> 
                \\<input type="radio" id="url-{[index]d}" name="url-picked" value="{[value]s}" {[checked]s}> 
                \\<label for="url-{[index]d}">{[value]s}</label>
            , .{.index = index, .value = value_escaped, .checked = checked});
            try w.writeAll("</p>");
            index += 1;
        }
    }

    try w.writeAll("<div>");
    try w.print(
        \\<input type="radio" id="url-html" name="url-picked" value="html" {s}> 
    , .{if (pick_index == index) "checked" else ""});
    try w.writeAll(
        \\<label for="url-html">Html as feed</label>
        \\<fieldset class='html-feed-inputs'>
        \\<legend>Html feed selectors and date format</legend>
    );
    try w.print(
        \\<p><label for="feed-container">Feed item selector</label></p>
        \\<input type="text" id="feed-container" name="selector-container" value="{s}"> 
    , .{try selector_value(req.arena, query, "selector-container")});
    try w.writeAll(
        \\<p>Rest of the fields are optional. And selector fields root (starting point) is feed item selector.</p>
    );
    try w.print(
        \\<p><label for="feed-link">Link selector (optional)</label></p>
        \\<p class="input-desc">Fallback is &lt;a&gt; href value</p>
        \\<input type="text" id="feed-link" name="selector-link" value="{s}"> 
    , .{try selector_value(req.arena, query, "selector-link")});
    try w.print(
        \\<p><label for="feed-heading">Heading selector (optional)</label></p>
        \\<p class="input-desc">Fallback are headings (&lt;h1&gt;-&lt;h6&gt;). After that whole item container's text will be used.</p>
        \\<input type="text" id="feed-heading" name="selector-heading" value="{s}"> 
    , .{try selector_value(req.arena, query, "selector-heading")});
    try w.print(
        \\<p><label for="feed-date">Date selector (optional)</label></p>
        \\<p class="input-desc">Fallback is &lt;time&gt.</p>
        \\<input type="text" id="feed-date" name="selector-date" value="{s}"> 
    , .{try selector_value(req.arena, query, "selector-date")});
    try w.print(
        \\<p><label for="feed-date-format">Date format (optional)</label></p>
        \\<p class="input-desc">Fallback is date format that &lt;time&gt; uses.</p>
        \\<input type="text" id="feed-date-format" name="feed-date-format" value="{s}"> 
    , .{try selector_value(req.arena, query, "feed-date-format")});
    try w.writeAll(
        \\</fieldset>
    );
    try w.writeAll("</div>");
    try w.writeAll("</fieldset>");

    const tags_str: []const u8 = blk: {
        if (query.get("input-tags")) |tags_raw| {
            break :blk try parse.html_escape(req.arena, tags_raw);
        }
        break :blk "";
    };

    try w.print(
        \\<div>
        \\<p><label for="input-tags">Tags (optional)</label></p>
        \\<p class="input-desc">Tags are comma separated</p>
        \\<input id="input-tags" name="input-tags" value="{s}">
        \\</div>
    , .{tags_str});

    try w.writeAll(
        \\<a href="/feed/add">Cancel</a>
        \\<button class="btn btn-primary">Add new feed</button>
        \\</form>
    );

    try w.writeAll("</main>");
    try Layout.write_foot(w);
}

fn selector_value(allocator: mem.Allocator, query: *httpz.key_value.StringKeyValue, key: []const u8) ![]const u8 {
    if (query.get(key)) |raw| {
        const value = mem.trim(u8, raw, &std.ascii.whitespace);
        if (value.len > 0) {
            return try parse.html_escape(allocator, value);
        }
    }
    return "";
}

fn feed_add_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    resp.status = 303;

    const form_data = try req.formData();
    const url_input = form_data.get("input-url");
    const tags_input = blk: {
        if (form_data.get("input-tags")) |val| {
            const trimmed = mem.trim(u8, val, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                break :blk trimmed;
            }
        }
        break :blk null;
    };

    var location_arr = try std.ArrayList(u8).initCapacity(req.arena, 64);

    var url_tmp: ?[]const u8 = null;
   
    if (url_input) |url_raw| {
        const url = mem.trim(u8, url_raw, &std.ascii.whitespace);
        if (url.len == 0) {
            const location = blk: {
                if (tags_input) |val| {
                    const c: std.Uri.Component = .{ .raw = val };
                    break :blk try std.fmt.allocPrint(req.arena, "/feed/add?error=url-missing&input-tags={%}", .{c});
                }
                break :blk "/feed/add?error=url-missing";
            };

            resp.header("Location", location);
            return;
        }

        _ = std.Uri.parse(url) catch {
            const url_comp: std.Uri.Component = .{ .raw = url };
            try std.fmt.format(location_arr.writer(), "/feed/add?error=invalid-url&input-url={%}", .{url_comp});
            if (tags_input) |val| {
                const tags_comp: std.Uri.Component = .{ .raw = val };
                try std.fmt.format(location_arr.writer(), "&input-tags={%}", .{tags_comp});
            }

            resp.header("Location", location_arr.items);
            return;
        };
        url_tmp = url;
    }

    const feed_url = mem.trim(u8, url_tmp.?, &std.ascii.whitespace);

    if (try db.get_feed_id_with_url(feed_url)) |feed_id| {
        const url_comp: std.Uri.Component = .{ .raw = feed_url };
        try std.fmt.format(location_arr.writer(), "/feed/add?feed-exists={d}&input-url={%}", .{feed_id, url_comp});
        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try std.fmt.format(location_arr.writer(), "&input-tags={%}", .{c2});
        }

        resp.header("Location", location_arr.items);
        return;
    }

    // try to add new feed
    const App = @import("app.zig").App;
    var app = App{.storage = db.*, .allocator = req.arena};

    var fetch = try app.fetch_response(req.arena, feed_url);
    defer fetch.deinit();

    const feed_options = FeedOptions.fromResponse(fetch.resp);

    if (feed_options.content_type == .html) {
        const url_comp: std.Uri.Component = .{ .raw = feed_url };
        try location_arr.writer().print("/feed/pick?input-url={%}", .{url_comp});
        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try location_arr.writer().print("&input-tags={%}", .{c2});
        }
        const html_parsed = try html.parse_html(req.arena, feed_options.body);
        for (html_parsed.links) |link| {
            const url_final = try fetch.req.get_url_slice();
            const uri_final = try std.Uri.parse(url_final);
            const url_str = try feed_types.url_create(req.arena, link.link, uri_final);
            const uri_component: std.Uri.Component = .{ .raw = url_str };
            try location_arr.writer().print("&url={%}", .{uri_component});
        }
        resp.header("Location", location_arr.items);
        return;
    }

    var add_opts: Storage.AddOptions = .{ .feed_opts = feed_options };
    add_opts.feed_opts.feed_url = try fetch.req.get_url_slice();
    const feed_id = try db.addFeed(req.arena, add_opts);

    if (tags_input) |raw| {
        errdefer |err| {
            std.log.err("Failed to add tags for new feed '{s}'. Error: {}", .{add_opts.feed_opts.feed_url, err});
        }

        var iter = mem.splitScalar(u8, raw, ',');
        const cap = mem.count(u8, raw, ",") + 1;
        var tags_arr = try std.ArrayList([]const u8).initCapacity(req.arena, cap);
        defer tags_arr.deinit();

        while (iter.next()) |tag| {
            const trimmed = mem.trim(u8, tag, &std.ascii.whitespace);
            tags_arr.appendAssumeCapacity(trimmed);
        }

        try db.tags_add(tags_arr.items);
        const tags_ids_buf = try req.arena.alloc(usize, tags_arr.items.len);
        const tags_ids = try db.tags_ids(tags_arr.items, tags_ids_buf);
        try db.tags_feed_add(feed_id, tags_ids);
    }

    // TODO: check, fetch favicon
    // TODO: push fetching favicon to another thread

    try location_arr.writer().print("/feed/add?success={d}", .{feed_id});
    resp.header("Location", location_arr.items);
}

fn feed_add_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };

    try Layout.write_head(w, "Add feed", .{});

    try body_head_render(req, db, w, .{});

    try w.writeAll("<main class='box'>");

    try w.writeAll("<h2>Add feed</h2>");

    var query = try req.query();
    if (query.get("success")) |id_raw| {
        if (std.fmt.parseUnsigned(usize, id_raw, 10)) |feed_id| {
            try w.print(
                \\<p>Feed added.
                \\<a href="/feed/{d}">Got to feed page</a>.
                \\</p>
            , .{feed_id});
        } else |_| {
            try w.writeAll("<p>Failed to get added feed id.</p>");
        }
    } else if (query.get("feed-exists")) |raw_value| {
        const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
        if (std.fmt.parseUnsigned(usize, value, 10)) |feed_id| {
            try w.print(
                \\<p>Feed already exists.
                \\<a href="/feed/{d}">Got to feed page</a>.
                \\</p>
            , .{feed_id});
        } else |_| {
            try w.writeAll("<p>Failed to get id for feed that already exists.</p>");
        }
    } else if (query.get("error")) |value| {
        if (mem.eql(u8, "invalid-url", value)) {
            try w.writeAll("<p>Failed to add feed.");
            try w.writeAll(" Invalid url.");
            try w.writeAll("</p>");
        } else if (mem.eql(u8, "url-missing", value)) {
            try w.writeAll("<p>Fill in feed/page url</p>");
        }
    }

    const url = blk: {
        if (query.get("input-url")) |url_raw| {
            break :blk url_raw;
        }
        break :blk "";
    };

    const url_escaped = try parse.html_escape(req.arena, url);
    try w.print(
        \\<form action="/feed/add" method="POST" class="flow" style="--flow-space(--space-m)">
        \\<div>
        \\<p><label for="input-url">Feed or page url</label></p>
        \\<input id="input-url" name="input-url" value="{s}">
        \\</div>
    , .{url_escaped});

    const tags_str: []const u8 = blk: {
        if (query.get("input-tags")) |tags_raw| {
            break :blk try parse.html_escape(req.arena, tags_raw);
        }
        break :blk "";
    };

    try w.print(
        \\<div>
        \\<p><label for="input-tags">Tags (optional)</label></p>
        \\<p class="input-desc">Tags are comma separated</p>
        \\<input id="input-tags" name="input-tags" value="{s}">
        \\</div>
    , .{tags_str});

    try w.writeAll(
        \\<button class="btn btn-primary">Add new feed</button>
        \\</form>
    );

    try w.writeAll("</main>");
    try Layout.write_foot(w);
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

    resp.status = 303;
    const fields: Storage.FeedFields = .{
        .feed_id = feed_id,
        .title = title,
        .page_url = page_url,
        .icon_url = icon_url,
        .tags = tags.items,
    };
    const db = &global.storage;
    db.update_feed_fields(req.arena, fields) catch {
        const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error=feed", .{req.url.path});
        resp.header("Location", url_redirect);
        return;
    };

    if (try db.html_selector_has(feed_id)) {
        const selector_item = get_field(form_data, "html-item-selector") catch return error.MissingFormFieldHtmlItemSelector;
        if (selector_item == null) {
            const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error=item-selector", .{req.url.path});
            resp.header("Location", url_redirect);
            return;
        }

        const update_fields: parse.HtmlOptions = .{
            .selector_container = selector_item.?,
            .selector_link = get_field(form_data, "html-link-selector") catch return error.MissingFormFieldHtmlLinkSelector,
            .selector_heading = get_field(form_data, "html-title-selector") catch return error.MissingFormFieldHtmlTitleSelector,
            .selector_date = get_field(form_data, "html-date-selector") catch return error.MissingFormFieldHtmlDateSelector,
            .date_format = get_field(form_data, "html-date-format") catch return error.MissingFormFieldHtmlDateFormat,
        };

        db.html_selector_update(feed_id, update_fields) catch {
            const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error=html", .{req.url.path});
            resp.header("Location", url_redirect);
            return;
        };
    }

    const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?success=", .{req.url.path});
    resp.header("Location", url_redirect);
}

fn get_field(form_data: *httpz.key_value.StringKeyValue, key: []const u8) !?[]const u8 {
    const value = form_data.get(key) orelse return error.MissingField;
    const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len > 0) {
        return trimmed;
    }
    return null;
}

// Example output: "15:05 21.12.2024"
const date_format_readable = "{d:0>2}:{d:0>2} {d:0>2}.{d:0>2}.{d:0>4}";
const date_format_readable_len = std.fmt.count(date_format_readable, .{
    13, 34, 22, 11, 2024
});

fn date_readable(utc_sec: i64) [date_format_readable_len]u8 {
    var result: [date_format_readable_len]u8 = undefined;
    var date_for_human = Datetime.fromSeconds(@floatFromInt(utc_sec));
    date_for_human = date_for_human.shiftTimezone(&@import("zig-datetime").timezones.Europe.Helsinki);
    _ = std.fmt.bufPrint(
        &result, date_format_readable,
        .{
            date_for_human.time.hour,
            date_for_human.time.minute,
            date_for_human.date.day,
            date_for_human.date.month,
            date_for_human.date.year,
        }
    ) catch unreachable;

    return result;
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

    resp.content_type = .HTML;

    var etag_buf: [64]u8 = undefined;

    if (try db.get_latest_feed_change(id)) |latest| {
        const etag_out = try std.fmt.bufPrint(&etag_buf, "\"{x}\"", .{latest});
        if (resp_cache(req, resp, etag_out)) {
            resp.status = 304;
            return;
        }
    }

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

    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };

    if (feed.title.len > 0) {
        try Layout.write_head(w, "Feed - {s}", .{feed.title});
    } else {
        try Layout.write_head(w, "Feed", .{});
    }

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
        const page_url_encoded = try parse.html_escape(req.arena, page_url);
        try w.print(
        \\<a href="{s}" class="inline-block">{s}</a>
        , .{page_url_encoded, page_url_encoded});
    } else {
        try w.writeAll("no url");
    }
    try w.writeAll("</p>");

    const feed_url_encoded_attr = try parse.html_escape(req.arena, feed.feed_url);
    const feed_url_encoded = try parse.html_escape(req.arena, feed.feed_url);
    try w.print(
        \\<p>Feed url: <a href="{s}">{s}</a></p>
    , .{ feed_url_encoded_attr, feed_url_encoded });

    var date_buf: [date_len_max]u8 = undefined;
    var relative_buf: [32]u8 = undefined;
    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());

    // TODO: item times won't update when cached. Probably use JS on the frontend
    // 1) Just dates
    // 2) Use JS to use relative times
    if (try db.feed_last_update(feed.feed_id)) |last_update| {
        const date_for_machine = timestampToString(&date_buf, last_update);
        try w.print(
            \\<p>Last update was
            \\<relative-time>
            \\<time datetime={s}>{s}</time>
            \\</relative-time>
            \\</p>
        , .{
            date_for_machine,
            date_readable(last_update),
        });
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
        } else if (mem.eql(u8, "feed", error_value)) {
            try w.writeAll("<p>Failed to update feed</p>");
        } else if (mem.eql(u8, "html", error_value)) {
            try w.writeAll("<p>Failed to update feed html fields</p>");
        } else if (mem.eql(u8, "item-selector", error_value)) {
            try w.writeAll("<p>Fill in 'Feed item selector' field</p>");
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

    const page_url = blk: {
        if (feed.page_url) |page_url| {
            const page_url_escaped = try parse.html_escape(req.arena, page_url);
            break :blk page_url_escaped;
        }
        break :blk "";
    };

    const icon_url = blk: {
        if (feed.icon_url) |icon_url| {
            const icon_url_escaped = try parse.html_escape(req.arena, icon_url);
            break :blk icon_url_escaped;
        }
        break :blk "";
    };

    try w.print(inputs_fmt, .{
        .title = try parse.html_escape(req.arena, feed.title), 
        .page_url = page_url,
        .icon_url = icon_url,
    });

    if (mem.eql(u8, page_url, feed.feed_url)) {
        if (try db.html_selector_get(req.arena, feed.feed_id)) |html_opts| {
            const selector_template = 
                \\<div>
                \\<p><label for="html-{[name]s}-selector">{[label]s}</label></p>
                \\<input type="text" value="{[value]s}" name="html-{[name]s}-selector" id="html-{[name]s}-selector">
                \\</div>
            ;

            // TODO: need to escape html_opts.* values. Those are user input so
            // can be anything.
            try w.writeAll("<fieldset>");
            try w.writeAll("<legend>Html 'feed' options</legend>");
            try w.print(
                selector_template,
                .{ 
                    .label = "Feed item selector",
                    .name = "item",
                    .value = try parse.html_escape(req.arena, html_opts.selector_container),
                }
            );
            try w.print(
                selector_template,
                .{ 
                    .label = "Feed item link selector",
                    .name = "link",
                    .value = try parse.html_escape(req.arena, html_opts.selector_link orelse ""),
                }
            );
            try w.print(
                selector_template,
                .{ 
                    .label = "Feed item title selector",
                    .name = "title",
                    .value = try parse.html_escape(req.arena, html_opts.selector_heading orelse ""),
                }
            );
            try w.print(
                selector_template,
                .{ 
                    .label = "Feed item date selector",
                    .name = "date",
                    .value = try parse.html_escape(req.arena, html_opts.selector_date orelse ""),
                }
            );

            try w.print(
                \\<div>
                \\<p><label for="html-date-format">Date format</label></p>
                \\<input type="text" value="{s}" name="html-date-format" id="html-date-format">
                \\</div>
            , .{try parse.html_escape(req.arena, html_opts.date_format orelse "")});

            try w.writeAll("</fieldset>");
        }
    }
    
    try w.writeAll("<fieldset>");
    try w.writeAll("<legend>Tags</legend>");
    try w.writeAll("<div class='feed-tag-list flow'>");
    for (tags_all, 0..) |tag, i| {
        const is_checked = blk: {
            for (feed_tags) |f_tag| {
                if (mem.eql(u8, tag, f_tag)) {
                    break :blk "checked";
                }
            }
            break :blk "";
        };
        const tag_escaped = try parse.html_escape(req.arena, tag);
        try tag_input_render(w, .{
            .tag = tag_escaped,
            .tag_index = i,
            .is_checked = is_checked,
            .prefix = "tag-edit-",
            .label_class = "line-count-1",
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
        path = path[0..path.len - 1];
    }
    try w.print("<form action='{s}/delete' method='POST'>", .{path});
    try w.writeAll("<button class='btn btn-secondary'>Delete feed</button>");
    try w.writeAll("</form>");
    try w.writeAll("</div>");

    try w.writeAll("<h2>Feed items</h2>");
    try w.writeAll("<ul class='feed-item-list flow' style='--flow-space: var(--space-m)'>");
    for (items) |item| {
        try w.print("<li class='feed-item {s}'>", .{""});
        try item_render(w, req.arena, item, .{});
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>");

    try w.writeAll("</main>");
    try Layout.write_foot(w);
}

fn relative_time_from_seconds(buf: []u8,  seconds: i64) ![]const u8 {
    if (seconds <= 0) {
        return try std.fmt.bufPrint(buf, "now", .{});
    }

    const day = @divFloor(seconds, std.time.s_per_day);
    const hour = @divFloor(seconds, std.time.s_per_hour);
    const minute = @divFloor(seconds, std.time.s_per_min);
    const second = seconds;

    const year = @divFloor(day, 365);
    const month = @divFloor(day, 365 / 12);

    if (year > 0) {
        const plural = if (year > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} year{s}", .{year, plural});
    } else if (month > 0) {
        const plural = if (month > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} month{s}", .{month, plural});
    } else if (day > 0) {
        const plural = if (day > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} day{s}", .{day, plural});
    } else if (hour > 0) {
        const plural = if (hour > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} hour{s}", .{hour, plural});
    } else if (minute > 0) {
        const plural = if (minute > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} minute{s}", .{minute, plural});
    }

    const plural = if (second > 1) "s" else "";
    return try std.fmt.bufPrint(buf, "{d} second{s}", .{second, plural});
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
    } else if (mem.endsWith(u8, req.url.path, "relative-time.js")) {
        src = try get_file(req.arena, "server/relative-time.js");
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

fn has_encoding(req: *const httpz.Request, value: []const u8) bool {
    if (req.header("accept-encoding")) |raw| {
        var iter = mem.splitScalar(u8, raw, ',');
        while (iter.next()) |encoding| {
            const trimmed = std.mem.trim(u8, encoding, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(value, trimmed)) {
                return true;
            }
        }
    }

    return false;
}

fn compressor_setup(req: *httpz.Request, resp: *httpz.Response) !?std.compress.gzip.Compressor(httpz.Response.Writer.IOWriter) { 
    if (!has_encoding(req, "gzip")) {
        return null;
    }

    resp.header("Content-Encoding", "gzip");

    return try std.compress.gzip.compressor(resp.writer(), .{});
}

fn compressor_finish(compressor: *std.compress.gzip.Compressor(httpz.Response.Writer.IOWriter)) void {
    compressor.finish() catch |err| {
        std.log.warn("Failed to finish gzip compression. Error: {}\n", .{err});
    };
}


fn latest_added_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    var date_buf: [29]u8 = undefined;
    var etag_buf: [64]u8 = undefined;

    if (try db.get_latest_change()) |latest_created| {
        const countdown = db.countdown_utc() catch 0 orelse 0;
        const etag_out = try std.fmt.bufPrint(&etag_buf, "\"{x}-{x}\"", .{latest_created, countdown});
        if (resp_cache(req, resp, etag_out)) {
            resp.status = 304;
            return;
        }
    }
    
    resp.content_type = .HTML;

    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };
    
    try Layout.write_head(w, "Home - latest added feed items", .{});

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

    if (try db.next_update_countdown()) |countdown| {
        if (countdown > 0) {
            const countdown_ts = std.time.timestamp() + countdown;
            var date = Datetime.fromSeconds(@floatFromInt(countdown_ts));
            date = date.shiftTimezone(&@import("zig-datetime").timezones.Europe.Helsinki);

            try w.print("<time-relative>(<time datetime={s}>{d:0>2}:{d:0>2} {d:0>2}.{d:0>2}.{d:0>4}</time>)</time-relative>", .{
                timestampToString(&date_buf, countdown_ts),
                date.time.hour,
                date.time.minute,
                date.date.day,
                date.date.month,
                date.date.year,
            });
        } else if (countdown <= 0) {
            try w.writeAll("<span>Update now</span>");
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
        try w.writeAll("<p class='ml-m'>No feeds have been added in the previous 3 days</p>");
    }
    try w.writeAll("</main>");

    try Layout.write_foot(w);
}

fn item_latest_render(w: anytype, allocator: std.mem.Allocator, item: FeedItemRender, feed: types.Feed) !void {
    try item_render(w, allocator, item, .{.class = "truncate-2"});

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

fn tag_delete(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const tag_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const tag_id = std.fmt.parseUnsigned(usize, tag_id_raw, 10) catch return error.InvalidIdParam;

    const db = &global.storage;
    resp.status = 301;
    db.tags_remove_with_id(tag_id) catch {
        // On failure redirect to feed page. Display error message
        resp.header("Location", "/tags?error=delete");
        return;
    };

    resp.header("Location", "/tags?success=");
}

fn tag_edit_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const tag_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const tag_id = std.fmt.parseUnsigned(usize, tag_id_raw, 10) catch return error.InvalidIdParam;

    const db = &global.storage;
    resp.status = 301;

    var location_arr = try std.ArrayList(u8).initCapacity(req.arena, 64);
    const form_data = try req.formData();
    const tag_name_form = form_data.get("tag-name") orelse {
        try location_arr.writer().print("/tag/{d}/edit?error=invalid-form", .{tag_id});
        resp.header("Location", location_arr.items);
        return;
    };

    const tag_id_form_raw = form_data.get("tag-id") orelse {
        try location_arr.writer().print("/tag/{d}/edit?error=invalid-form", .{tag_id});
        resp.header("Location", location_arr.items);
        return;
    };
    const tag_id_form = std.fmt.parseUnsigned(usize, tag_id_form_raw, 10) catch return error.InvalidIdParam;

    try db.tag_update(.{ .tag_id = tag_id_form, .name = tag_name_form });

    try location_arr.writer().print("/tag/{d}/edit?success=", .{tag_id});
    resp.header("Location", location_arr.items);
}

fn tag_edit(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const tag_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const tag_id = std.fmt.parseUnsigned(usize, tag_id_raw, 10) catch return error.InvalidIdParam;

    const db = &global.storage;

    const tag = try db.tag_with_id(req.arena, tag_id) orelse {
        resp.status = 301;
        resp.header("Location", "/tags?error=missing");
        return;
    };

    resp.content_type = .HTML;

    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };

    try Layout.write_head(w, "Edit tag: {s}", .{tag.name});

    try body_head_render(req, db, w, .{});
    
    try w.writeAll("<div class='ml-m'>");
    try w.print("<h2>Edit tag: {s}</h2>", .{tag.name});

    const query_kv = try req.query();
    if (query_kv.get("success")) |_| {
        try w.writeAll("<div>");
        try w.writeAll("<p>Saved changes</p>");
        try w.writeAll("</div>");
    } else if (query_kv.get("error")) |val| {
        if (mem.eql(u8, "invalid-form", val)) {
            try w.writeAll("<div>");
            try w.writeAll("<p>Invalid form</p>");
            try w.writeAll("</div>");
        }
    }

    try w.writeAll("<form class='flow' style='--flow-space: var(--space-m)' method='post'>");
    try w.writeAll("<div>");
    try w.writeAll("<p>");
    try w.writeAll("<label for='tag-name'>Tag name</label>");
    try w.writeAll("</p>");
    try w.print("<input class='input-small' type='text' id='tag-name' name='tag-name' value='{s}'>", .{tag.name});
    try w.writeAll("</div>");
    try w.print("<input type='hidden' name='tag-id' value='{d}'>", .{tag.tag_id});
    try w.print("<a class='btn btn-secondary mr-s' href='/tag/{}/delete'>Delete</a>", .{tag.tag_id});
    try w.writeAll("<button class='btn btn-primary'>Save changes</button>");
    try w.writeAll("</div>");
    try w.writeAll("</form>");

    try w.writeAll("</div>");

    try Layout.write_foot(w);
}

fn tags_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    var etag_buf: [64]u8 = undefined;

    if (try db.get_tags_change()) |latest_created| {
        const etag_out = try std.fmt.bufPrint(&etag_buf, "\"{x}\"", .{latest_created});
        if (resp_cache(req, resp, etag_out)) {
            resp.status = 304;
            return;
        }
    }

    resp.content_type = .HTML;

    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };

    try Layout.write_head(w, "Tags", .{});

    try body_head_render(req, db, w, .{});

    const tags = try db.tags_all_with_ids(req.arena);
    try w.writeAll("<main class='box'>");
    try w.writeAll("<h2>Tags</h2>");

    const query_kv = try req.query();
    if (query_kv.get("error")) |err_value| {
        if (mem.eql(u8, "delete", err_value)) {
            try w.writeAll("<p>Failed to delete tag</p>");
        } else if (mem.eql(u8, "missing", err_value)) {
            try w.writeAll("<p>Tag doesn't exist</p>");
        } 
    } else if (query_kv.get("success")) |_| {
        try w.writeAll("<p>Tag deleted</p>");
    }

    try w.writeAll("<ul role='list'>");
    for (tags) |tag| {
        try w.writeAll("<li class='tag-item'>");
        const tag_name_escaped = try parse.html_escape(req.arena, tag.name);
        try tag_link_print(w, tag_name_escaped);
        try w.print("<a href='/tag/{d}/delete' rel='nofollow'>Delete</a>", .{tag.tag_id});
        try w.print("<a href='/tag/{d}/edit'>Edit</a>", .{tag.tag_id});
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>");
    try w.writeAll("</main>");

    try Layout.write_foot(w);
}

const Layout = struct {
    const splits = base_split();
    const head = splits[0]; 
    const foot = splits[1];
    const head_splits = head_split(head);
    const head_top = head_splits[0];
    const head_bottom = head_splits[1].?;

    pub fn write_head(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
        if (head_top) |top| {
            try writer.writeAll(top);
            try writer.print(fmt, args);
        }
        try writer.writeAll(head_bottom);
    }
    pub fn write_foot(writer: anytype) !void {
        try writer.writeAll(foot);
    }

    fn base_split() [2][]const u8 {
        const base_layout = @embedFile("./layouts/base.html");
        var base_iter = mem.splitSequence(u8, base_layout, "[content]");
        const head_tmp = base_iter.next() orelse @compileError("Failed to split base.html");
        const foot_tmp = base_iter.next() orelse @compileError("Failed to split base.html. Missing split string '[content]' ");
        return .{head_tmp, foot_tmp};
    }

    fn head_split(input: []const u8) [2]?[]const u8 {
        var base_iter = mem.splitSequence(u8, input, "[title]");
        const top = base_iter.next() orelse @compileError("Failed to split base.html");
        if (base_iter.next()) |bottom| {
            return .{top, bottom};
        }
        return .{null, top};
    }

};

fn resp_cache(req: *httpz.Request, resp: *httpz.Response, etag: []const u8) bool {
    resp.header("Etag", etag);
    resp.header("Cache-control", "no-cache");

    if (req.method == .GET or req.method == .HEAD) {
        if (req.header("if-none-match")) |if_match| {
            return mem.eql(u8, if_match, etag);
        }
    }

    return false;
}

fn feeds_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    var etag_buf: [64]u8 = undefined;

    if (try db.get_latest_change()) |latest_created| {
        const etag_out = try std.fmt.bufPrint(&etag_buf, "\"{x}\"", .{latest_created});
        if (resp_cache(req, resp, etag_out)) {
            resp.status = 304;
            return;
        }
    }
    
    resp.content_type = .HTML;

    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };

    try Layout.write_head(w, "Feeds", .{});

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

    try Layout.write_foot(w);
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
            try item_render(w, allocator, item, .{.class = "truncate-2"});
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

const ItemRenderOptions = struct {
    class: []const u8 = "",
};

fn item_render(w: anytype, allocator: std.mem.Allocator, item: FeedItemRender, opts: ItemRenderOptions) !void {
    try timestamp_render(w, item.updated_timestamp);

    const item_title = if (item.title.len > 0) try parse.html_escape(allocator, item.title) else title_placeholder;

    if (item.link) |link| {
        const item_link_fmt =
            \\<a href="{[link]s}" class="item-link {[class]s}" title="{[title]s}">{[title]s}</a>
        ;
        const link_escaped = try parse.html_escape(allocator, link);
        try w.print(item_link_fmt, .{ .title = item_title, .link = link_escaped, .class = opts.class });
    } else {
        const item_title_fmt =
            \\<p class="{[class]s}" title="{[title]s}">{[title]s}</p>
        ;
        try w.print(item_title_fmt, .{ .title = item_title, .class = opts.class });
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

    const menu_items = [_]struct{path: []const u8, name: []const u8}{
        .{.path = "/", .name = "Home"},
        .{.path = "/feeds", .name = "Feeds"},
        .{.path = "/tags", .name = "Tags"},
        .{.path = "/feed/add", .name = "Add feed"},
    };

    try w.writeAll("<nav>");
    const first_item = menu_items[0];
    try nav_link_render(first_item.path, first_item.name, w, req.url.path);

    for (menu_items[1..]) |item| {
        try w.writeAll("<span>|</span>");
        try nav_link_render(item.path, item.name, w, req.url.path);
    }
    try w.writeAll("</nav>");
    try w.writeAll("</div>");

    try w.writeAll("<div class='filter-wrapper'>");
    try w.writeAll("<h2 class='sidebar-heading'>Filter feeds</h2>");
    const tags = try db.tags_all(allocator);
    try w.writeAll("<form action='/feeds' class='flow'>");
    // NOTE: don't want tags-only button to be the 'default' button. This is
    // used when enter is pressed in input (text) field.
    try w.writeAll(
    \\<button aria-hidden="true" style="display: none">Default form action</button>
    );
    try w.writeAll("<fieldset class='tags flow' style='--flow-space: var(--space-2xs)'>");
    try w.writeAll("<legend class='visually-hidden'>Tags</legend>");
    try w.writeAll("<h3 class='form-heading' aria-hidden='true'>Tags</h3>");

    try w.writeAll("<div class='tag-list flow'>");
    try untagged_label_render(w, opts.has_untagged);
    for (tags, 0..) |tag, i| {
        try tag_label_render(w, tag, i + 1, opts.tags_checked);
    }
    try w.writeAll("</div>");
    try w.writeAll("</fieldset>");
    try w.writeAll("<button name='tags-only'>Filter tags only</button>");

    try w.print(
    \\<div>
    \\  <label class="form-heading" for="search_value">Filter term</label>
    \\  <div><input type="search" name="search" id="search_value" value="{s}"></div>
    \\  <button class="form-submit">Filter</button>
    \\</div>
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
    try w.print("<a class='line-count-1' href='/?untagged=' title='untagged'>{s}</a>", .{ untagged });
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
    \\<a class='line-count-1' href="/feeds?tag={[tag]s}" title="{[tag]s}">{[tag]s}</a>
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
const datetime = @import("zig-datetime").datetime;
const Datetime = datetime.Datetime;
const FeedItemRender = types.FeedItemRender;
const config = @import("app_config.zig");
const html = @import("./html.zig");
const feed_types = @import("./feed_types.zig");
const FeedOptions = feed_types.FeedOptions;
const parse = @import("./app_parse.zig");
