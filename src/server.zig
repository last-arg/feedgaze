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
    // const storage = try Storage.init(null);
    const storage = try Storage.init("./tmp/feeds.db");
    try start_server(storage, .{.port = 5882 });
}

const Global = struct {
    storage: Storage, 
    layout: Layout,
    is_updating: bool = false,
    etag_out: []const u8,
    static_file_hashes: StaticFileHashes,
    icon_manage: IconManage,
};

const IconFileType = enum {
    png, // image/png
    jpeg, // image/jpeg
    jpg, // image/jpeg
    webp, // image/webp
    avif, // image/avif
    svg, // image/svg+xml
    ico, // image/x-icon

    fn from_string(str: []const u8) ?@This() {
        if (mem.eql(u8, str, "x-icon")) {
            return .ico;
        } else if (mem.eql(u8, str, "jpg")) {
            return .jpg;
        }
        return std.meta.stringToEnum(@This(), str);
    }

    pub fn to_content_type(self: @This()) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .jpg => "image/jpeg",
            .webp => "image/webp",
            .avif => "image/avif",
            .svg => "image/svg+xml",
            .ico => "image/x-icon",
        };
    }

    pub fn to_string(value: @This()) []const u8 {
        return switch (value) {
            .png => ".png",
            .jpeg => ".jpeg",
            .jpg => ".jpg",
            .webp => ".webp",
            .avif => ".avif",
            .svg => ".svg",
            .ico => ".ico",
        };
    }
};

pub const IconManage = struct {
    storage: Cache,

    const Cache = std.MultiArrayList(struct{
        icon_id: u64,
        icon_data: []const u8,
        is_inline: bool = false,
        icon_url: []const u8,
        file_type: ?IconFileType = null,
        data_hash: u64,
    });

    pub fn init(icons: []Storage.Icon, allocator: std.mem.Allocator) !@This() {
        var cache: Cache = .empty;
        errdefer cache.deinit(allocator);
        try cache.ensureTotalCapacity(allocator, icons.len);
        var hasher = std.hash.Wyhash.init(0);

        for (icons) |*icon| {
            var is_inline = false;
            const data, const file_type = blk: {
                if (data_image(icon.icon_data)) |data_img| {
                    is_inline = true;
                    const page_url_decoded = std.Uri.percentDecodeInPlace(@constCast(data_img.data));
                    break :blk .{page_url_decoded, data_img.file_type};
                } else if (file_type_from_data(icon.icon_data)
                    orelse file_type_from_url(icon.icon_url)
                ) |file_type| {
                    break :blk .{icon.icon_data, file_type};
                } else {
                    std.log.warn("Failed add icon to server cache. Icon (or page link): '{s}'", .{icon.icon_url});
                    continue;
                }
            };

            std.hash.autoHashStrat(&hasher, icon.icon_data, .Deep);
            cache.appendAssumeCapacity(.{
                .icon_id = icon.icon_id,
                .icon_data = data,
                .is_inline = is_inline,
                .icon_url = icon.icon_url,
                .file_type = file_type,
                .data_hash = hasher.final(),
            });
        } 

        return .{
            .storage = cache,
        };
    }

    fn is_png(data: []const u8) bool {
        const png_sig = .{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        return mem.startsWith(u8, data, &png_sig);
    }

    fn is_avif(data: []const u8) bool {
        const sig = .{0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66};
        return mem.startsWith(u8, data[4..], &sig);
    }

    fn is_jpg(data: []const u8) bool {
        const sig_start = .{ 0xFF, 0xD8 };
        const sig_end = .{ 0xFF, 0xD9};

        return mem.startsWith(u8, data, &sig_start)
            or mem.endsWith(u8, data, &sig_end);
    }

    fn is_webp(data: []const u8) bool {
        const sig_from_0 = .{ 0x52, 0x49, 0x46, 0x46 };
        const sig_from_8 = .{ 0x57, 0x45, 0x42, 0x50 };
        return mem.startsWith(u8, data, &sig_from_0)
            or mem.startsWith(u8, data[8..], &sig_from_8);
    }

    fn is_ico(data: []const u8) bool {
        const sig = .{0x00, 0x00, 0x01, 0x00};
        return mem.startsWith(u8, data, &sig);
    }
    
    fn file_type_from_data(data: []const u8) ?IconFileType {
        if (is_png(data)) {
            return .png;
        } else if (is_jpg(data)) {
            return .jpg;
        } else if (is_webp(data)) {
            return .webp;
        } else if (is_ico(data)) {
            return .ico;
        } else if (is_avif(data)) {
            return .avif;
        }
         
        return null;
    }

    fn file_type_from_url(input: []const u8) ?IconFileType {
        const url = std.Uri.parse(input) catch return null;
        const path = util.uri_component_val(url.path);
        var iter = mem.splitBackwardsScalar(u8, path, '.');
        const filetype_raw = iter.first();
        return IconFileType.from_string(filetype_raw);
    }

    pub const DataImage = struct {
        file_type: IconFileType,
        data: []const u8,
    };

    fn data_image(data: []const u8) ?DataImage {
        if (!mem.startsWith(u8, data, "data:")) {
            return null;
        }

        const index_end = mem.indexOfScalarPos(u8, data, 5, ',') orelse return null;

        var file_type_opt: ?IconFileType = null;
        const info_raw = data[5..index_end];
        var iter = mem.splitScalar(u8, info_raw, ';');
        while (iter.next()) |kv| {
            if (!mem.startsWith(u8, kv, "image/")) {
                continue;
            }
            const value = kv[6..];
            const end = mem.indexOfScalar(u8, value, '+') orelse value.len;
            if (IconFileType.from_string(value[0..end])) |file_type| {
                file_type_opt = file_type;
                break;
            }
        }

        const file_type = file_type_opt orelse return null; 

        return .{
            .file_type = file_type,
            .data = data[index_end + 1..],
        };
    }

    pub fn index_by_id(self: *const @This(), id: u64) ?usize {
        for (self.storage.items(.icon_id), 0..) |icon_id, i| {
            if (id == icon_id) {
                return i;
            }
        }

        return null;
    }

    pub fn icon_src_by_id(self: *const @This(), buf: []u8, id: u64) ?[]const u8 {
        const index = self.index_by_id(id) orelse return null;
        const icon = self.storage.get(index);
        if (icon.file_type) |ft| {
            return std.fmt.bufPrint(buf, "/icons/{x}{s}", .{icon.data_hash, ft.to_string()})
                catch null;
        }

        return null;
    }

    pub fn index_by_hash(self: *const @This(), hash_raw: []const u8) !?usize {
        const hash = std.fmt.parseUnsigned(u64, hash_raw, 16) catch return error.InvalidHash;

        for (self.storage.items(.data_hash), 0..) |data_hash, i| {
            if (data_hash == hash) {
                return i;
            }
        }

        return null;
    }
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }
};

const StaticFileHashes = std.StaticStringMap([]const u8);
const md5_len = std.crypto.hash.Md5.digest_length;

fn hash_static_file(comptime path: []const u8) [md5_len]u8 {
    @setEvalBranchQuota(1000000);
    var buf: [md5_len]u8 = undefined; 
    const c = @embedFile(path);
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update(c);
    hash.final(buf[0..]);
    return buf;
}

const static_files = if (builtin.mode != .Debug) .{
    // .{ &hash_static_file("server/open-props-colors.css"), "open-props-colors.css" },
    .{ &hash_static_file("server/kelp.css"), "kelp.css" },
    .{ &hash_static_file("server/style.css"), "style.css" },
    .{ &hash_static_file("server/main.js"), "main.js" },
    .{ &hash_static_file("server/relative-time.js"), "relative-time.js" },
} else .{
    // .{ "open-props-colors.css", "open-props-colors.css" },
    .{ "kelp.css", "kelp.css" },
    .{ "style.css", "style.css" },
    .{ "main.js", "main.js" },
    .{ "relative-time.js", "relative-time.js" },
    .{ "reload.js", "reload.js" },
};

const static_file_hashes = StaticFileHashes.initComptime(static_files);

pub fn start_server(storage: Storage, opts: types.ServerOptions) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const layout = Layout.init(allocator, storage); 

    const etag_out = try std.fmt.allocPrint(allocator, "{x}", .{std.time.timestamp()});
    defer allocator.free(etag_out);

    const db = @constCast(&storage);
    const icons = try db.icon_all(allocator);
    defer allocator.free(icons);
    var icon_manage = try IconManage.init(icons, allocator);
    defer icon_manage.deinit(allocator);

    var global: Global = .{
        .storage = storage,
        .layout = layout,
        .etag_out = etag_out,
        .static_file_hashes = static_file_hashes,
        .icon_manage = icon_manage,
    };
    const server_config: httpz.Config = .{
        .port = opts.port,  
        .request = .{
            .max_form_count = 10,
        }
    };
    var server = try httpz.Server(*Global).init(allocator, server_config, &global);
    defer {
        server.stop();
        server.deinit();
    }
    var router = try server.router(.{});

    router.get("/", latest_added_get, .{});
    router.head("/", latest_added_head, .{});
    router.get("/feeds", feeds_get, .{});
    router.get("/tags", tags_get, .{});
    router.post("/update", update_post, .{});

    router.get("/tag/:id/edit", tag_edit, .{});
    router.post("/tag/:id/edit", tag_edit_post, .{});
    // TODO: this should be POST?
    router.get("/tag/:id/delete", tag_delete, .{});

    router.get("/feed/add", feed_add_get, .{});
    router.post("/feed/add", feed_add_post, .{});

    router.get("/feed/pick", feed_pick_get, .{});
    router.post("/feed/pick", feed_pick_post, .{});

    router.get("/feed/:id", feed_get, .{});
    router.post("/feed/:id", feed_post, .{});
    router.post("/feed/:id/delete", feed_delete, .{});

    router.get("/public/*", public_get, .{});
    router.head("/public/*", public_head, .{});
    router.get("/icons/:filename", icons_get, .{});
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

fn update_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    resp.status = 303;

    if (!global.is_updating) {
        global.is_updating = true;
        var app: App = .{ .storage = global.storage };
        var item_arena = std.heap.ArenaAllocator.init(req.arena);
        defer item_arena.deinit();

        const feed_updates = try global.storage.getFeedsToUpdate(req.arena, null, .{});
        for (feed_updates) |f_update| {
            _ = item_arena.reset(.retain_capacity);
            _ = app.update_feed(&item_arena, f_update) catch {};
        }
        global.is_updating = false;
    }

    resp.header("Location", "/");
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
    var app = App{.storage = db.*};

    var fetch = try app.fetch_response(req.arena, feed_url);
    defer fetch.deinit();

    const feed_options = FeedOptions.fromResponse(fetch.resp);
    var add_opts: Storage.AddOptions = .{ .feed_opts = feed_options };
    add_opts.feed_opts.feed_url = try fetch.req.get_url_slice();

    const html_opts: ?parse.HtmlOptions = if (feed_options.content_type == .html) .{
        .selector_container = selector_container,
        .selector_link = try get_field(form_data, "selector-link"),
        .selector_heading = try get_field(form_data, "selector-heading"),
        .selector_date = try get_field(form_data, "selector-date"),
        .date_format = try get_field(form_data, "feed-date-format"),
    } else null;

    // TODO: fetch and add favicon in another thread?
    // probably need to copy (alloc) feed_url because request might clean (dealloc) up
    if (add_opts.feed_opts.icon == null) {
        add_opts.feed_opts.icon = App.fetch_icon(req.arena, add_opts.feed_opts.feed_url, null) catch null;
    }
    
    var parsing: parse = try .init(add_opts.feed_opts.body);

    const parsed_feed = try parsing.parse(req.arena, html_opts, .{
        .feed_url = add_opts.feed_opts.feed_url,
    });
  
    const feed_id = try db.addFeed(parsed_feed, add_opts);

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

    const tags = try db.tags_all(req.arena);
    try global.layout.body_head_render(w, req.url.path, tags, .{});

    try w.writeAll("<main class='box'>");
    try w.writeAll("<h2>Add feed</h2>");

    if (query.get("feed-exists")) |raw_value| {
        const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
        if (std.fmt.parseUnsigned(usize, value, 10)) |feed_id| {
            try w.print(
                \\<p class="callout">Feed already exists.
                \\<a href="/feed/{d}">Got to feed page</a>.
                \\</p>
            , .{feed_id});
        } else |err| {
            std.log.warn("Failed to get parse feed id '{s}'. Error: {}", .{value, err});
            try w.writeAll("<p class='callout danger'>Enter valid feed ID.</p>");
        }
    } else if (query.get("error")) |value| {
        if (mem.eql(u8, "invalid-url", value)) {
            try w.writeAll("<p class='callout danger'>Enter valid url.</p>");
        } else if (mem.eql(u8, "url-missing", value)) {
            try w.writeAll("<p class='callout danger>Pick feed option.</p>");
        } else if (mem.eql(u8, "empty-selector", value)) {
            try w.writeAll("<p class='callout danger>Fill in 'Feed item selector'.</p>");
        } else if (mem.eql(u8, "pick-url", value)) {
            try w.writeAll("<p class='callout danger>Pick one of the feed options.</p>");
        }
    }

    try w.writeAll(
        \\<form action="/feed/pick" method="POST" class="flow" style="--flow-space: var(--size-4xl)">
    );
    try w.writeAll(
        \\<div>
        \\<label>Feed/Page link
        \\</label>
    );
    const url_escaped = try parse.html_escape(req.arena, url);
    try w.print("<input class='char-len-l' type='text' readonly name='input-url' value='{s}'>", .{url_escaped});
    try w.writeAll("</div>");

    try w.writeAll("<fieldset>");
    try w.writeAll("<legend>Pick feed to add</legend>");

    const pick_index = blk: {
        if (query.get("pick-index")) |raw| {
            break :blk std.fmt.parseInt(u32, raw, 10) catch 0;
        }
        break :blk 0;
    };

    try w.writeAll("<ul class='list-unstyled margin-end-0'>");
    var iter = query.iterator();
    var index: usize = 0;
    while (iter.next()) |kv| {
        if (mem.eql(u8, "url", kv.key)) {
            try w.writeAll("<li>");
            const value_escaped = try parse.html_escape(req.arena, kv.value);
            // const checked = if (pick_index == index) "checked" else "";
            const checked = "";
            try w.print(
                \\<input type="hidden" name="url" value="{[value]s}"> 
                \\<label for="url-{[index]d}">
                \\<input type="radio" id="url-{[index]d}" name="url-picked" value="{[value]s}" {[checked]s}> 
                \\{[value]s}
                \\</label>
            , .{.index = index, .value = value_escaped, .checked = checked});
            try w.writeAll("</li>");
            index += 1;
        }
    }

    try w.writeAll("<li>");
    try w.print(
        \\<label for="url-html">
        \\<input type="radio" id="url-html" name="url-picked" value="html" {s}> 
        \\Html as feed
        \\</label>
    , .{if (pick_index == index) "checked" else ""});
    try w.writeAll("</li>");
    try w.writeAll("</ul>");

    try w.writeAll(
        \\<div>
        \\<noscript>
        \\<p class="callout">
        \\Fill these fields if you picked "Html as feed".
        \\</p>
        \\</noscript>
        \\<div class='html-feed-inputs flow'>
    );
    try w.print(
        \\<div>
        \\<label for="feed-container">Html item selector</label>
        \\<input type="text" id="feed-container" name="selector-container" value="{s}"> 
        \\</div>
    , .{try selector_value(req.arena, query, "selector-container")});
    try w.writeAll(
        \\<p class="callout">Rest of the fields are optional. And selector fields root (starting point) is feed item selector.</p>
    );
    try w.print(
        \\<div>
        \\<div class="label-wrapper">
        \\<label for="feed-link">Html link selector (optional)</label>
        \\<em>Fallback is &lt;a&gt; href value</em>
        \\</div>
        \\<input type="text" id="feed-link" name="selector-link" value="{s}"> 
        \\</div>
    , .{try selector_value(req.arena, query, "selector-link")});
    try w.print(
        \\<div>
        \\<div class="label-wrapper">
        \\<label for="feed-heading">Html heading selector (optional)</label>
        \\<em>Fallback are headings (&lt;h1&gt;-&lt;h6&gt;). After that whole item container's text will be used.</em>
        \\</div>
        \\<input type="text" id="feed-heading" name="selector-heading" value="{s}"> 
        \\</div>
    , .{try selector_value(req.arena, query, "selector-heading")});
    try w.print(
        \\<div>
        \\<div class="label-wrapper">
        \\<label for="feed-date">Html date selector (optional)</label>
        \\<em>Fallback is &lt;time&gt.</em>
        \\</div>
        \\<input type="text" id="feed-date" name="selector-date" value="{s}"> 
        \\</div>
    , .{try selector_value(req.arena, query, "selector-date")});
    try w.print(
        \\<div>
        \\<div class="label-wrapper">
        \\<label for="feed-date-format">Html date format (optional)</label>
        \\<em>Fallback is date format that &lt;time&gt; uses.</em>
        \\</div>
        \\<input type="text" id="feed-date-format" name="feed-date-format" value="{s}"> 
        \\</div>
    , .{try selector_value(req.arena, query, "feed-date-format")});
    try w.writeAll(
        \\</div>
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
        \\<div class="label-wrapper">
        \\<label for="input-tags">Tags (optional)</label>
        \\<em>Tags are comma separated</em>
        \\</div>
        \\<input class="char-len-m" id="input-tags" name="input-tags" value="{s}">
        \\</div>
    , .{tags_str});

    try w.writeAll(
        \\<div class="form-actions">
        \\<button class="primary muted">Add new feed</button>
        \\<a href="/feed/add">Cancel</a>
        \\</div>
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
    var app = App{.storage = db.*};

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

    // TODO: fetch and add favicon in another thread?
    // probably need to copy (alloc) feed_url because request might clean (dealloc) up
    if (add_opts.feed_opts.icon == null) {
        add_opts.feed_opts.icon = App.fetch_icon(req.arena, add_opts.feed_opts.feed_url, null) catch null;
    }

    var parsing: parse = try .init(add_opts.feed_opts.body);

    const parsed_feed = try parsing.parse(req.arena, null, .{
        .feed_url = add_opts.feed_opts.feed_url,
    });

    const feed_id = try db.addFeed(parsed_feed, add_opts);

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

fn feed_add_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    if (try db.get_tags_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}\"", .{latest_created});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }

    var compressor = try compressor_setup(req, resp);
    defer if (compressor) |*c| compressor_finish(c);

    var w = blk: {
        if (compressor) |*c| {
            break :blk c.writer().any(); 
        }
        break :blk resp.writer().any();
    };

    try Layout.write_head(w, "Add feed", .{});

    const tags = try db.tags_all(req.arena);
    try global.layout.body_head_render(w, req.url.path, tags, .{});

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
            try w.writeAll("<p class='callout danger'>Enter valid feed/page link</p>");
        } else if (mem.eql(u8, "url-missing", value)) {
            try w.writeAll("<p class='callout danger'>Fill in feed/page link</p>");
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
        \\<form action="/feed/add" method="POST" class="flow" style="--flow-space: var(--size-4xl)">
        \\<div>
        \\<div><label for="input-url">Feed/Page link</label></div>
        \\<input type=text class="char-len-l" id="input-url" name="input-url" value="{s}">
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
        \\<div class='label-wrapper'>
        \\<label for="input-tags">Tags (optional)</label>
        \\<em>Tags are comma separated</em>
        \\</div>
        \\<input type=text class="char-len-m" id="input-tags" name="input-tags" value="{s}">
        \\</div>
    , .{tags_str});

    try w.writeAll(
        \\<button class="primary muted">Add new feed</button>
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
    const form_data = try req.formData();
    const action = form_data.get("action") orelse return error.MissingFormAction;

    if (mem.eql(u8, action, "delete")) {
        try feed_delete(global, req, resp);
        return;
    }

    if (!mem.eql(u8, action, "save")) {
        resp.status = 400;
        return;
    }

    const feed_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const feed_id = std.fmt.parseUnsigned(usize, feed_id_raw, 10) catch return error.InvalidIdParam;

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

    const db = &global.storage;

    const icon_id = blk: {
        const icon_url_trimmed = mem.trim(u8, icon_url, &std.ascii.whitespace);

        if (util.is_url(icon_url_trimmed)) {
            if (try db.icon_get_id(icon_url_trimmed)) |icon_id| {
                break :blk icon_id;
            } 

            // is url
            const http_client = @import("./http_client.zig");
            var req_http = try http_client.init(req.arena);
            defer req_http.deinit();

            const resp_image, const resp_body = req_http.fetch_image(icon_url_trimmed) catch break :blk null;
            defer resp_image.deinit();

            const resp_url = req_http.get_url_slice() catch |err| {
                std.log.warn("Failed to get requests effective url that was started by '{s}'. Error: {}", .{icon_url, err});
                break :blk null;
            };

            break :blk try db.icon_upsert(.{
                .url = resp_url,
                .data = resp_body,
            });
        } else if (util.is_svg(icon_url_trimmed)) {
            // Only inline svg allowed for icon
            const page_url_decoded = std.Uri.percentDecodeInPlace(@constCast(icon_url_trimmed));
            const data = try std.fmt.allocPrint(req.arena, "data:image/svg+xml,{s}", .{page_url_decoded});
            if (try db.icon_get_id(data)) |icon_id| {
                break :blk icon_id;
            } 

            break :blk try db.icon_upsert(.{
                .url = page_url,
                .data = data,
            });
        } else {
            std.log.info("User entered invalid icon input: '{s}'", .{icon_url_trimmed});
            // TODO: cancel updating feed?
            // TODO: make use aware of mistake
        }

        break :blk null;
    };

    resp.status = 303;
    const fields: Storage.FeedFields = .{
        .feed_id = feed_id,
        .title = title,
        .page_url = page_url,
        .icon_id = icon_id,
        .tags = tags.items,
    };
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
    date_for_human = date_for_human.shiftTimezone(@import("zig-datetime").timezones.Europe.Helsinki);
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

    if (try db.get_latest_feed_change(id)) |latest| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}\"", .{latest});
        if (resp_cache(req, resp, etag_out, .{})) {
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

    const title = feed.title orelse "";
    if (title.len > 0) {
        try Layout.write_head(w, "Feed - {s}", .{title});
    } else {
        try Layout.write_head(w, "Feed", .{});
    }

    const tags = try db.tags_all(req.arena);
    try global.layout.body_head_render(w, req.url.path, tags, .{});

    try w.writeAll("<main>");
    try w.writeAll("<h2>");
    if (feed.icon_id) |icon_id| {
        var buf: [128]u8 = undefined;
        if (global.icon_manage.icon_src_by_id(&buf, icon_id)) |path| {
            try w.print(
                \\<img class="feed-icon" src="{s}" alt="" aria-hidden="true">
            , .{path});
        }
    }
    try w.writeAll(if (title.len > 0) title else feed.page_url orelse feed.feed_url);
    try w.writeAll("</h2>");

    try w.writeAll("<div class='feed-info flow'>");
    try w.writeAll("<p>Page link: ");
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
        \\<p>Feed link: <a href="{s}">{s}</a></p>
    , .{ feed_url_encoded_attr, feed_url_encoded });

    var date_buf: [date_len_max]u8 = undefined;
    const now_sec: i64 = @intFromFloat(Datetime.now().toSeconds());

    if (try db.feed_last_update(feed.feed_id)) |last_update| {
        const date_for_machine = timestampToString(&date_buf, last_update);
        try w.print(
            \\<p>Last update was
            \\<em>
            \\<relative-time update="false">
            \\<time datetime={s}>{s}</time>
            \\</relative-time>
            \\</em>
            \\</p>
        , .{
            date_for_machine,
            date_readable(last_update),
        });
    }

    if (try db.next_update_feed(feed.feed_id)) |utc_sec| {
        const ts = now_sec + utc_sec;
        const date_for_machine = timestampToString(&date_buf, ts);
        try w.print(
            \\<p>Next update
            \\<em>
            \\<relative-time update="false">
            \\<time datetime={s}>{s}</time>
            \\</relative-time>
            \\</em>
            \\</p>
        , .{
            date_for_machine,
            date_readable(ts),
        });
        // TODO: add update link/button if can update now 
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
    
    try w.writeAll("<h3>Edit feed</h3>");
    try w.writeAll("<form class='flow' method='POST'>");

    const inputs_fmt = 
    \\<div>
    \\  <div><label for="title">Feed title</label></div>
    \\  <input class="char-len-l" type="text" id="title" name="title" value="{[title]s}">
    \\</div>
    \\<div>
    \\  <div><label for="page_url">Page link</label></div>
    \\  <input type="text" id="page_url" name="page_url" value="{[page_url]s}">
    \\</div>
    \\<div>
    \\  <div><label for="icon_url">Icon link</label></div>
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
        if (feed.icon_id) |icon_id| {
            if (global.icon_manage.index_by_id(icon_id)) |index| {
                if (global.icon_manage.storage.items(.is_inline)[index]) {
                    const icon_raw = global.icon_manage.storage.items(.icon_data)[index];
                    const icon_encoded = try html.encode(req.arena, icon_raw);
                    break :blk icon_encoded;
                }

                break :blk global.icon_manage.storage.items(.icon_url)[index];
            }
        }
        break :blk "";
    };

    try w.print(inputs_fmt, .{
        .title = try parse.html_escape(req.arena, title), 
        .page_url = page_url,
        .icon_url = icon_url,
    });

    if (mem.eql(u8, page_url, feed.feed_url)) {
        if (try db.html_selector_get(req.arena, feed.feed_id)) |html_opts| {
            const selector_template = 
                \\<div>
                \\<div><label for="html-{[name]s}-selector">{[label]s}</label></div>
                \\<input class='char-len-s' type="text" value="{[value]s}" name="html-{[name]s}-selector" id="html-{[name]s}-selector">
                \\</div>
            ;

            try w.writeAll("<fieldset class='flow'>");
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
                \\<div><label for="html-date-format">Date format</label></div>
                \\<input class="char-len-s" type="text" value="{s}" name="html-date-format" id="html-date-format">
                \\</div>
            , .{try parse.html_escape(req.arena, html_opts.date_format orelse "")});

            try w.writeAll("</fieldset>");
        }
    }
    
    try w.writeAll("<fieldset>");
    try w.writeAll("<legend>Tags</legend>");
    try w.writeAll("<div class='feed-tag-list'>");
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
        const tag_fmt = 
        \\<label for="{[prefix]s}{[tag_index]d}">
        \\<input type="checkbox" name="tag" id="{[prefix]s}{[tag_index]d}" value="{[tag]s}" {[is_checked]s}>
        \\<span class='truncate-1' title="{[tag]s}">{[tag]s}</span>
        \\</label>
        ;
        try w.print(tag_fmt, .{
            .tag = tag_escaped,
            .tag_index = i,
            .is_checked = is_checked,
            .prefix = "tag-edit-",
        });
    }
    try w.writeAll("</div>");
    try w.writeAll("</fieldset>");
    try w.writeAll(
        \\<div class="form-input">
        \\  <div>
        \\    <label for="new_tags">New tags</label>
        \\    <em>Tags are comma separated</em>
        \\  </div>
        \\  <input type="text" id="new_tags" name="new_tags">
        \\</div>
    );

    try w.writeAll("<div>");
    try btn_primary(w, "Save feed changes");
    try w.writeAll("</div>");
    try btn_delete(w, "Delete feed", .button);
    try w.writeAll("</form>");

    try w.writeAll("</div>");

    try w.writeAll("<h3>Feed items</h3>");
    if (items.len > 0) {
        try w.writeAll("<relative-time update=false format-style=narrow format-numeric=always>");
        try w.writeAll("<ul class='stack list-unstyled'>");
        for (items) |item| {
            try w.print("<li class='feed-item {s}'>", .{""});
            try item_render(w, req.arena, item, .{});
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");
        try w.writeAll("</relative-time>");
    } else {
        try w.writeAll("<p class='callout'>No feeds items in this feed.</p>");
    }

    try w.writeAll("</main>");
    try Layout.write_foot(w);
}

fn get_file(allocator: std.mem.Allocator, comptime path: []const u8) ![]const u8 {
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

fn btn_primary(w: anytype, text: []const u8) !void {
    try w.print("<button class='muted primary' name='action' value='save'>{s}</button>", .{text});
}

fn btn_delete(w: anytype, text: []const u8, btn_type: enum {button, link}) !void {
    switch (btn_type) {
        .button => {
            try w.print("<button class='outline danger' name='action' value='delete'>{s}</button>", .{text});
        },
        .link => {
            try w.print("<button class='btn-link padding-0 danger' name='action' value='delete'>{s}</button>", .{text});
        },
    }
}

fn public_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    var src: ?[]const u8 = null;
    if (mem.endsWith(u8, req.url.path, "main.js")) {
        src = try get_file(req.arena, "server/main.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "relative-time.js")) {
        src = try get_file(req.arena, "server/relative-time.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "reload.js")) {
        src = try get_file(req.arena, "server/reload.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "style.css")) {
        src = try get_file(req.arena, "server/style.css");
        resp.content_type = .CSS;
    } else if (mem.endsWith(u8, req.url.path, "kelp.css")) {
        src = try get_file(req.arena, "server/kelp.css");
        resp.content_type = .CSS;
    } else if (mem.endsWith(u8, req.url.path, "open-props-colors.css")) {
        src = try get_file(req.arena, "server/open-props-colors.css");
        resp.content_type = .CSS;
    }

    if (src) |body| {
        if (resp_cache(req, resp, global.etag_out, .{.cache_control = "public,max-age=31536000,immutable"})) {
            resp.status = 304;
            return;
        }

        var al = std.ArrayList(u8).init(req.arena);
        var fbs = std.io.fixedBufferStream(body);
        try std.compress.gzip.compress(fbs.reader(), al.writer(), .{});
        resp.header("content-encoding", "gzip");
        resp.body = al.items;
    }
}

fn get_file_last_modified(comptime path: []const u8) !i128 {
    var buf: [256]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "src/{s}", .{path});
    const file = try std.fs.cwd().openFile(p, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.mtime;
}

fn public_head(_: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    var last_modified: ?i128 = null;
    if (mem.endsWith(u8, req.url.path, "main.js")) {
        last_modified = try get_file_last_modified("server/main.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "relative-time.js")) {
        last_modified = try get_file_last_modified("server/relative-time.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "reload.js")) {
        last_modified = try get_file_last_modified("server/reload.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "style.css")) {
        last_modified = try get_file_last_modified("server/style.css");
        resp.content_type = .CSS;
    } else if (mem.endsWith(u8, req.url.path, "open-props-colors.css")) {
        last_modified = try get_file_last_modified("server/open-props-colors.css");
        resp.content_type = .CSS;
    }

    if (last_modified) |val| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}\"", .{val});
        resp.header("Etag", etag_out);
    }
}

fn icons_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const filename_raw = req.params.get("filename") orelse return error.NoFileName;
    var iter = mem.splitScalar(u8, filename_raw, '.');
    const filename_hash = iter.first();

    if (try global.icon_manage.index_by_hash(filename_hash)) |index| blk: {
        // Check if file type matches
        const file_type = global.icon_manage.storage.items(.file_type)[index];
        if (iter.next()) |file_type_raw| if (IconFileType.from_string(file_type_raw)) |ft_req| {
            if (file_type != ft_req) {
                std.log.warn("Request icon file type and current icon type don't match. Request icon type: {s}. Current icon type: {}.", .{file_type_raw, ft_req});
                break :blk;
            }
            resp.header("Content-Type", ft_req.to_content_type());
        };

        resp.header("Cache-control", "public,max-age=31536000,immutable");
        const body = body: {
            const data = global.icon_manage.storage.items(.icon_data)[index];
            if (mem.startsWith(u8, data, "data:")) {
                const index_comma = mem.indexOfScalarPos(u8, data, 5, ',') orelse data.len;
                const start = index_comma + 1;
                if (start < data.len) {
                    break :body data[start..];
                }
            }
            break :body data;
        };
        resp.body = body;
        return;
    }
    resp.status = 404;
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

fn latest_added_head(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    if (try db.get_latest_change()) |latest_created| {
        const countdown = db.next_update_timestamp() catch 0 orelse 0;
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest_created, countdown});
        _ = resp_cache(req, resp, etag_out, .{});
    }
    
    resp.content_type = .HTML;
}

fn latest_added_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    var date_buf: [29]u8 = undefined;

    if (try db.get_latest_change()) |latest_created| {
        const countdown = db.next_update_timestamp() catch 0 orelse 0;
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest_created, countdown});
        if (resp_cache(req, resp, etag_out, .{})) {
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

    const tags = try db.tags_all(req.arena);
    try global.layout.body_head_render(w, req.url.path, tags, .{});

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

    try w.writeAll("<div class='main-heading'>");
    try w.writeAll("<h2>Latest added</h2>");

    if (try db.next_update_timestamp()) |countdown_ts| {
        const now_ts = std.time.timestamp();
        if (countdown_ts <= now_ts) {
            try w.writeAll("<div class=\"heading-info\">");
            if (countdown_ts != 0) if (try db.most_recent_update_timestamp()) |recent_timestamp| {
                const date_readable_str = date_readable(recent_timestamp);
                try w.print(
                    \\<p>Last update was <relative-time update="false"><time datetime="{s}">{s}</time></relative-time>.</p>
                , .{
                    timestampToString(&date_buf, recent_timestamp),
                    date_readable_str,
                });
            };

            try w.writeAll(
                \\<form method=POST action=/update>
                \\<button href="/update">Check for updates</button>.
                \\Might take some time.
                \\</form>
                \\</div>
            );
        } else if (countdown_ts > now_ts) {
            const date_readable_str = date_readable(countdown_ts);
            try w.print("<p>Next update <relative-time update=false><time datetime={s}>{s}</time></relative-time> ({s})</p>", .{
                timestampToString(&date_buf, countdown_ts),
                date_readable_str,
                date_readable_str,
            });
        }
    }
    try w.writeAll("</div>");
    
    const items = try db.get_items_latest_added(req.arena);
    if (items.len > 0) {
        var ids_al = try std.ArrayList(usize).initCapacity(req.arena, items.len);
        defer ids_al.deinit();
        for (items) |item| { ids_al.appendAssumeCapacity(item.feed_id); }
        const feeds = try db.get_feeds_with_ids(req.arena, ids_al.items);
        try w.writeAll("<relative-time update=false format-style=narrow format-numeric=always>");

        try w.writeAll("<ul class='stack list-unstyled'>");
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
            try item_latest_render(w, req.arena, item, feed, global);
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");
        try w.writeAll("</relative-time>");
    } else {
        try w.writeAll("<p class='callout'>No feed items have been added in the previous 3 days</p>");
    }
    try w.writeAll("</main>");

    try Layout.write_foot(w);
}

fn item_latest_render(w: anytype, allocator: std.mem.Allocator, item: FeedItemRender, feed: types.Feed, global: *const Global,) !void {
    try item_render(w, allocator, item, .{.class = "truncate-2"});

    const url = try std.Uri.parse(feed.page_url orelse feed.feed_url);
    const title = feed.title orelse "";
    try w.print(
        \\<div class="item-extra">
        \\<a href="/feed/{d}" title="{s}">{s}</a>
        \\<div class="feed-external-url">
    , .{ feed.feed_id, title, title });

    try w.print(
        \\<a href="{}" rel=noreferrer>
    , .{ url });

    var buf: [128]u8 = undefined;
    if (feed.icon_id) |icon_id| {
        if (global.icon_manage.icon_src_by_id(&buf, icon_id)) |path| {
            try w.print(
                \\<img class="feed-icon" src="{s}" alt="" aria-hidden="true">
            , .{path});
        }
    }

    try w.print(
        \\<span>{+}</span></a>
        \\</div>
        \\</div>
    , .{ url });
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
    const tag = db.tag_with_id(req.arena, tag_id) catch {
        // On failure redirect to feed page. Display error message
        resp.header("Location", "/tags?error=delete");
        return;
    } orelse {
        // On failure redirect to feed page. Display error message
        resp.header("Location", "/tags?error=delete");
        return;
    };

    db.tags_remove_with_id(tag_id) catch {
        // On failure redirect to feed page. Display error message
        resp.header("Location", "/tags?error=delete");
        return;
    };

    var location_arr = try std.ArrayList(u8).initCapacity(req.arena, 64);
    try location_arr.writer().print("/tags?success={s}", .{tag.name});
    resp.header("Location", location_arr.items);
}

fn tag_edit_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const form_data = try req.formData();
    const action = form_data.get("action") orelse return error.MissingFormAction;

    if (mem.eql(u8, action, "delete")) {
        try tag_delete(global, req, resp);
        return;
    }

    if (!mem.eql(u8, action, "save")) {
        resp.status = 400;
        return;
    }

    const tag_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const tag_id = std.fmt.parseUnsigned(usize, tag_id_raw, 10) catch return error.InvalidIdParam;

    const db = &global.storage;
    resp.status = 301;

    var location_arr = try std.ArrayList(u8).initCapacity(req.arena, 64);
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

    if (try db.get_tags_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}\"", .{latest_created});
        if (resp_cache(req, resp, etag_out, .{})) {
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

    try Layout.write_head(w, "Edit tag: {s}", .{tag.name});

    const tags = try db.tags_all(req.arena);
    try global.layout.body_head_render(w, req.url.path, tags, .{});
    
    try w.writeAll("<main>");
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

    try w.writeAll("<form class='flow' method='post'>");
    try w.writeAll("<div>");
    try w.writeAll("<div>");
    try w.writeAll("<label for='tag-name'>Tag name</label>");
    try w.writeAll("</div>");
    try w.print("<input class='char-len-s' type='text' id='tag-name' name='tag-name' value='{s}'>", .{tag.name});
    try w.writeAll("</div>");
    try w.print("<input type='hidden' name='tag-id' value='{d}'>", .{tag.tag_id});

    try w.writeAll("<div>");
    try btn_primary(w, "Save changes");
    try w.writeAll("</div>");
    try btn_delete(w, "Delete tag", .button);

    try w.writeAll("</div>");
    try w.writeAll("</form>");

    try w.writeAll("</main>");

    try Layout.write_foot(w);
}

fn tags_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    if (try db.get_tags_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}\"", .{latest_created});
        if (resp_cache(req, resp, etag_out, .{})) {
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

    const tags = try db.tags_all(req.arena);
    try global.layout.body_head_render(w, req.url.path, tags, .{});

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

    try w.writeAll("<ul class='tags-all stack list-unstyled' role='list'>");
    const tag_ids = try db.tags_all_with_ids(req.arena);
    for (tag_ids) |tag| {
        try w.writeAll("<li class='tag-item'>");
        const tag_name_escaped = try parse.html_escape(req.arena, tag.name);
        try tag_link_print(w, tag_name_escaped, .link);
        try w.print("<div class='cluster'>", .{});
        try w.print("<a href='/tag/{d}/edit'>Edit</a>", .{tag.tag_id});
        try w.print(
            \\<form action="/tag/{d}/delete" method="POST">
        , .{tag.tag_id});
        try btn_delete(w, "Delete", .link);
        try w.writeAll("</form>");

        try w.print("</div>", .{});
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
    const head_middle = head_splits[1];
    const head_bottom = head_splits[2];

    tags_last_modified: i64 = 0,
    sidebar_form_html: std.ArrayList(u8), 
    storage: Storage,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, storage: Storage) @This() {
        const html_output = std.ArrayList(u8).init(allocator);
        errdefer html_output.deinit();
        return .{
            .sidebar_form_html = html_output,
            .storage = storage,
            .allocator = allocator,
        };
    }

    pub fn write_static_files(writer: anytype) !void {
        // write <link> and <script>
        for (static_file_hashes.keys()) |key| {
            const name = static_file_hashes.get(key).?;

            const last_dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
            const filetype = name[last_dot_index + 1..];

            if (mem.eql(u8, filetype, "css")) {
                try writer.writeAll("<link rel=stylesheet type='text/css' href='/public/");
            } else if (mem.eql(u8, filetype, "js")) {
                try writer.writeAll("<script");
                if (std.mem.eql(u8, name, "main.js")) {
                    try writer.writeAll(" defer");
                } else if (std.mem.eql(u8, name, "relative-time.js")) {
                    try writer.writeAll(" async type=module");
                }
                try writer.writeAll(" src='/public/");
            }

            for (key) |c| {
                try writer.print("{x}", .{c});
            }

            try writer.writeAll("-");
            try writer.writeAll(name);

            try writer.writeAll("'>");
            if (mem.eql(u8, filetype, "js")) {
                try writer.writeAll("</script>");
            }
        }
    }

    pub fn write_head(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
        try writer.writeAll(head_top);
        try writer.print(fmt, args);
        try writer.writeAll(head_middle);
        try write_static_files(writer);
        try writer.writeAll(head_bottom);
    }

    pub fn write_foot(writer: anytype) !void {
        try writer.writeAll(foot);
    }

    pub fn cache_sidebar_form(self: *@This()) !bool {
        if (try self.storage.get_tags_change()) |last_modified| {
            if (last_modified != self.tags_last_modified) {
                const tags = try self.storage.tags_all(self.allocator);
                defer self.allocator.free(tags);
                try self.sidebar_form_html.resize(0);
                try write_sidebar_form_new(
                    self.sidebar_form_html.writer(), tags, .{}
                );
                self.tags_last_modified = last_modified; 
            }
            return true;
        }
        return false;
    }

    fn write_sidebar_form(self: *@This(), w: anytype, tags: [][]const u8, opts: HeadOptions) !void {
        const use_cached = opts.search.len == 0 and opts.tags_checked.len == 0 and !opts.has_untagged;
        if (use_cached) {
            if (try self.cache_sidebar_form()) {
                try w.writeAll(self.sidebar_form_html.items);
                return;
            }
        }

        try write_sidebar_form_new(w, tags, opts);
    }

    fn write_sidebar_form_new(w: anytype, tags: [][]const u8, opts: HeadOptions) !void {
        try w.writeAll("<details>");
        try w.writeAll("<summary>");
        try w.writeAll("Filter feeds");
        try w.writeAll("</summary>");
        try w.writeAll("<div class='filter-wrapper'>");
        try w.writeAll("<form action='/feeds' class='stack'>");
        // NOTE: don't want tags-only button to be the 'default' button. This is
        // used when enter is pressed in input (text) field.
        try w.writeAll(
        \\<button aria-hidden="true" style="display: none">Default form action</button>
        );
        try w.writeAll("<fieldset class='tags stack'>");
        try w.writeAll("<legend>Tags</legend>");

        try w.writeAll("<div class='tag-list stack'>");
        try untagged_label_render(w, opts.has_untagged);
        for (tags, 0..) |tag, i| {
            try tag_label_render(w, tag, i + 1, opts.tags_checked);
        }
        try w.writeAll("</div>");
        try w.writeAll("</fieldset>");
        try w.writeAll("<div><button class='muted secondary' name='tags-only'>Filter tags only</button></div>");

        try w.print(
        \\<div>
        \\  <label class="form-heading" for="search_value">Filter feeds</label>
        \\  <div class="input-search-wrapper"><input type="search" name="search" id="search_value" value="{s}"></div>
        \\  <button class="form-submit muted primary">Filter all</button>
        \\</div>
        , .{ opts.search });

        try w.writeAll("</form>");
        try w.writeAll("</div>");
        try w.writeAll("</details>");
    }

    pub fn body_head_render(self: *@This(), w: anytype, request_url_path: []const u8, tags: [][]const u8, opts: HeadOptions) !void {
        try w.writeAll("<header class='body-header'>");

        try w.writeAll("<div class='nav'>");
        try w.writeAll("<h1>");
        try nav_link_render("/", "feedgaze", w, request_url_path);
        try w.writeAll("</h1>");
        try w.writeAll("<span>|</span>");

        const menu_items = [_]struct{path: []const u8, name: []const u8}{
            .{.path = "/feeds", .name = "Feeds"},
            .{.path = "/tags", .name = "Tags"},
            .{.path = "/feed/add", .name = "Add feed"},
        };

        try w.writeAll("<nav>");
        const first_item = menu_items[0];
        try nav_link_render(first_item.path, first_item.name, w, request_url_path);

        for (menu_items[1..]) |item| {
            try w.writeAll("<span>|</span>");
            try nav_link_render(item.path, item.name, w, request_url_path);
        }
        try w.writeAll("</nav>");
        try w.writeAll("</div>");

        try self.write_sidebar_form(w, tags, opts);

        try w.writeAll("</header>");
    }

    fn base_split() [2][]const u8 {
        const base_layout = @embedFile("./layouts/base.html");
        var base_iter = mem.splitSequence(u8, base_layout, "[content]");
        const head_tmp = base_iter.next() orelse @compileError("Failed to split base.html");
        const foot_tmp = base_iter.next() orelse @compileError("Failed to split base.html. Missing split string '[content]' ");
        return .{head_tmp, foot_tmp};
    }

    fn head_split(input: []const u8) [3][]const u8 {
        @setEvalBranchQuota(2000);
        var base_iter = mem.splitSequence(u8, input, "[title]");
        const top = base_iter.next() orelse @compileError("Failed to split base.html");
        const tmp_bottom = base_iter.next() orelse @compileError("Failed to split base.html");
        var bottom_iter = mem.splitSequence(u8, tmp_bottom, "[links_and_scripts]");
        const middle = bottom_iter.next() orelse @compileError("Failed to split base.html");
        const bottom = bottom_iter.next() orelse @compileError("Failed to split base.html");
        return .{top, middle, bottom};
    }

};

const CacheOptions = struct {
    cache_control: []const u8 = "no-cache",
};

fn resp_cache(req: *httpz.Request, resp: *httpz.Response, etag: []const u8, opts: CacheOptions) bool {
    resp.header("Etag", etag);
    resp.header("Cache-control", opts.cache_control);

    if (req.method == .GET or req.method == .HEAD) {
        if (req.header("if-none-match")) |if_match| {
            return mem.eql(u8, if_match, etag);
        }
    }

    return false;
}

fn feeds_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = &global.storage;

    if (try db.get_latest_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}\"", .{latest_created});
        if (resp_cache(req, resp, etag_out, .{})) {
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

    const tags = try db.tags_all(req.arena);
    try global.layout.body_head_render(w, req.url.path, tags, .{ 
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
        \\  <h2>Feeds</h2>
        \\  <div class="cluster">
        \\  <button class="outline js-expand-all">Expand all</button>
        \\  <button class="outline js-collapse-all">Collapse all</button>
        \\  </div>
        \\</header>
    );
    if (feeds.len > 0) {
        try feeds_and_items_print(w, req.arena, db, feeds, global);
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
            \\<p class='callout'>No feeds to show</p>
        );
    }
    try w.writeAll("</main>");

    try Layout.write_foot(w);
}

fn feeds_and_items_print(w: anytype, allocator: std.mem.Allocator,  db: *Storage, feeds: []types.Feed, global: *Global) !void {
    try w.writeAll("<div class='flow' style='--flow-space: var(--size-6xl)'>");
    var buf: [128]u8 = undefined;
    for (feeds) |feed| {
        try w.writeAll("<article class='feed'>");
        try w.writeAll("<header>");

        try w.writeAll("<div class='feed-header-top'>");
        if (feed.icon_id) |icon_id| {
            if (global.icon_manage.icon_src_by_id(&buf, icon_id)) |path| {
                try w.print(
                    \\<img class="feed-icon" src="{s}" alt="" aria-hidden="true">
                , .{path});
            }
        }
        try feed_render(w, feed);
        try feed_edit_link_render(w, feed.feed_id);
        try w.writeAll("</div>");

        const tags = try db.feed_tags(allocator, feed.feed_id);
        if (tags.len > 0) {
            try w.writeAll("<div class='feed-tags'>");
            try w.writeAll("<ul class='list-unstyled' aria-label='Feed tags'>");
            for (tags) |tag| {
                try w.writeAll("<li>");
                try tag_link_print(w, tag, .badge);
                try w.writeAll("</li>");
            }
            try w.writeAll("</ul>");
            try w.writeAll("</div>");
        }
        try w.writeAll("</header>");
        
        const items = try db.feed_items_with_feed_id(allocator, feed.feed_id);
        if (items.len == 0) {
            continue;
        }

        const date_in_sec: i64 = @intFromFloat(Datetime.now().toSeconds());

        var hide_index_start = items.len;
        const age_1day_ago = date_in_sec - std.time.s_per_day;

        for (items[1..], 1..) |item, i| {
            if (item.created_timestamp < age_1day_ago) {
                hide_index_start = i - 1;
                break;
            }
        }

        try w.writeAll("<relative-time update=false format-style=narrow format-numeric=always>");
        try w.writeAll("<ul class='stack list-unstyled'>");
        for (items, 0..) |item, i| {
            const hidden = if (hide_index_start > 0 and hide_index_start == i) "hide-after" else "";
            try w.print("<li class='feed-item {s}'>", .{hidden});

            try item_render(w, allocator, item, .{.class = "truncate-2"});
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");
        try w.writeAll("</relative-time>");
        const aria_expanded = if (hide_index_start != items.len) "false" else "true";
        try w.print(
            \\<footer class="feed-footer">
            \\  <button class="outline js-feed-item-toggle" aria-expanded="{s}">
            \\    <span class="toggle-expand">Expand</span>
            \\    <span class="toggle-collapse">Collapse</span>
            \\  </button>
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
            \\<a href="{[link]s}" class="item-link {[class]s}" title="{[title]s}" rel=noreferrer>{[title]s}</a>
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

fn feed_render(w: anytype, feed: types.Feed) !void {
    const title = blk: {
        if (feed.title) |title| {
            if (title.len > 0) {
                break :blk title;
            }
        }
        break :blk title_placeholder;
    };

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

fn untagged_label_render(w: anytype, has_untagged: bool) !void {
    try w.writeAll("<div class='tag'>");
    const is_checked: []const u8 = if (has_untagged) "checked" else "";
    const tag_fmt = 
    \\<input type="checkbox" name="untagged" id="untagged" {[is_checked]s}>
    \\<label class="visually-hidden" for="untagged">{[value]s}</label>
    ;
    try w.print(tag_fmt, .{ .value = untagged, .is_checked = is_checked });
    try w.print("<a class='truncate-1' href='/?untagged=' title='untagged'>{s}</a>", .{ untagged });
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
    try tag_link_print(w, tag, .link);
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
    \\<input type="checkbox" name="tag" id="{[prefix]s}{[tag_index]d}" value="{[tag]s}" {[is_checked]s}>
    \\<label class="{[label_class]s}" for="{[prefix]s}{[tag_index]d}">{[tag]s}</label>
    ;
    try w.print(tag_fmt, args);
}

fn tag_link_print(w: anytype, tag: []const u8, tag_type: enum{link, badge}) !void {
    const class = switch(tag_type) {
        .link => "truncate-1",
        .badge => "badge"
    };
    const tag_link_fmt = 
    \\<a class='{[class]s}' href="/feeds?tag={[tag]s}" title="{[tag]s}">{[tag]s}</a>
    ;

    try w.print(tag_link_fmt, .{ .class = class, .tag = tag });
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
const s = @import("storage.zig");
const Storage = s.Storage;
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
const parse = @import("./feed_parse.zig");
const App = @import("app.zig").App;
const builtin = @import("builtin");
const util = @import("util.zig");
