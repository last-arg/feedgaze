const std = @import("std");
const httpz = @import("httpz");
const s = @import("storage.zig");
const Storage = s.Storage;
const print = std.debug.print;
const mem = std.mem;
const types = @import("./feed_types.zig");
const Datetime = @import("zdt").Datetime;
const FeedItemRender = types.FeedItemRender;
const config = @import("app_config.zig");
const html = @import("./html.zig");
const feed_types = @import("./feed_types.zig");
const parse = @import("./feed_parse.zig");
const App = @import("app.zig").App;
const builtin = @import("builtin");
const util = @import("util.zig");
const AddRule = @import("add_rule.zig");
const http_client = @import("./http_client.zig");
const image = @import("./image.zig");
const comptimePrint = std.fmt.comptimePrint;
const pages = @import("templates/pages.zig");

pub const icon_input_max_size = 8 * 1024;
const cookie_key = "last-item-added-timestamp";

const static_files_hash = blk: {
    var hasher = std.hash.Wyhash.init(0);
    var buf: [feed_types.Icon.u64_hex_max_length] u8 = undefined;

    for (pages.static_files_map) |file| {
        const key = std.fmt.bufPrint(&buf, "{x}", .{file.hash}) catch unreachable;
        hasher.update(key);
    }

    break :blk hasher.final();
};

// For fast compiling and testing
pub fn main() !void {
    // const storage = try Storage.init(null);
    const storage = try Storage.init("./tmp/feeds.db");
    try start_server(storage, .{.port = 5882 });
}

const Global = struct {
    io: std.Io,
    storage: *Storage, 
    is_updating: bool = false,
    icon_manage: *IconManage,
    progress: std.Progress.Node,
    core_count: usize,
};

const IconFileType = image.Type;

pub const IconManage = struct {
    cache: Cache,
    allocator: std.mem.Allocator,
    storage: Storage,

    url_string_bytes: ArrayList(u8) = .empty,
    data_string_bytes: std.Io.Writer.Allocating,
    hash_string_bytes: ArrayList(u8) = .empty,

    const ArrayList = std.ArrayList;

    const Location = struct {
        start: u32, // inclusive
        end: u32, // exclusive
    };

    const Cache = std.MultiArrayList(struct{
        icon_id: types.IconRender.ID,
        icon_data: Location,
        icon_url: Location,
        file_type: IconFileType,
        hash: Location,
    });

    pub fn init(allocator: std.mem.Allocator, storage: Storage) @This() {
        return .{
            .cache = .empty,
            .allocator = allocator,
            .storage = storage,
            .data_string_bytes = .init(allocator),
        };
    }

    pub fn add(self: *@This(), icon: types.IconRender) !usize {
        const data, const file_type = blk: {
            if (image.Type.from_data(icon.icon_data)
                orelse file_type_from_uri(icon.icon_url)
            ) |file_type| {
                break :blk .{icon.icon_data, file_type};
            } else {
                std.log.warn("Unknown icon from '{f}'", .{icon.icon_url});
                return error.UnknownIcon;
            }
        };

        const hash_val = std.mem.trim(u8, icon.etag_or_last_modified_or_hash, &.{'W', '/', '"'});
        // Hashes used as url path name. Can't have slashes (/) 
        std.mem.replaceScalar(u8, @constCast(hash_val), '/', '_');

        const url_start = self.url_string_bytes.items.len; 
        var buf: [1024]u8 = undefined;
        const icon_url = try std.fmt.bufPrint(&buf, "{f}", .{icon.icon_url});
        try self.url_string_bytes.appendSlice(self.allocator, icon_url);
        const url_end = self.url_string_bytes.items.len; 

        const data_start = self.data_string_bytes.written().len; 
        if (file_type == .svg) {
            var buf_data: [std.compress.flate.max_window_len]u8 = undefined;
            try self.data_string_bytes.writer.ensureUnusedCapacity(std.compress.flate.max_window_len);
            var c = try std.compress.flate.Compress.init(&self.data_string_bytes.writer, &buf_data, .gzip, .default);
            try c.writer.writeAll(data);
            try c.writer.flush();
        } else {
            try self.data_string_bytes.writer.writeAll(data);
            try self.data_string_bytes.writer.flush();
        }

        const data_end = self.data_string_bytes.written().len; 

        const hash_start = self.hash_string_bytes.items.len; 
        try self.hash_string_bytes.appendSlice(self.allocator, hash_val);
        const hash_end = self.hash_string_bytes.items.len; 
        
        const index = self.cache.len;
        try self.cache.append(self.allocator, .{
            .icon_id = icon.icon_id,
            .icon_data = .{ .start = @intCast(data_start), .end = @intCast(data_end) },
            .icon_url = .{ .start = @intCast(url_start), .end = @intCast(url_end) },
            .file_type = file_type,
            .hash = .{ .start = @intCast(hash_start), .end = @intCast(hash_end) },
        });
        return index;
    }

    fn file_type_from_uri(uri: std.Uri) ?IconFileType {
        const path = util.uri_component_val(uri.path);
        var iter = mem.splitBackwardsScalar(u8, path, '.');
        const filetype_raw = iter.first();
        return IconFileType.from_string(filetype_raw);
    }

    pub fn index_by_id(self: *@This(), id: types.IconRender.ID) ?usize {
        if (id == .unassigned) return null;

        for (self.cache.items(.icon_id), 0..) |icon_id, i| {
            if (id == icon_id) {
                return i;
            }
        }

        const icon_opt = self.storage.icon_by_id(self.allocator, id) catch |err| {
            std.log.warn("Failed to get icon ID for feed with ID {}. Error: {}", .{id, err});
            return null;
        };

        if (icon_opt) |icon| {
            const index = self.add(icon) catch |err| {
                std.log.warn("Failed to add icon to server cache. Error: {}", .{err});
                return null;
            };

            return index;
        }

        return null;
    }

    pub fn get_icon_info(self: *@This(), id: types.IconRender.ID) ?struct {hash: []const u8, file_type: []const u8} {
        const index = self.index_by_id(id) orelse return null;
        const icon = self.cache.get(index);
        const hash = self.hash_string_bytes.items[icon.hash.start..icon.hash.end];
        const ft = icon.file_type;
        return .{.hash = hash, .file_type = ft.to_string()};
    }

    pub fn index_by_hash(self: *const @This(), filename_hash: []const u8) !?usize {
        for (self.cache.items(.hash), 0..) |hash_loc, i| {
            if (mem.eql(u8, hash_string_from_loc(self, hash_loc), filename_hash)) {
                return i;
            }
        }

        return null;
    }

    fn hash_string_from_loc(self: *const @This(), loc: Location) []const u8 {
        return self.hash_string_bytes.items[loc.start..loc.end];
    }

    pub fn get_data_string_by_index(self: *@This(), index: usize) []const u8 {
        const icon_data = self.cache.items(.icon_data)[index];
        return self.data_string_bytes.written()[icon_data.start..icon_data.end];
    }

    pub fn get_url_string_by_index(self: *const @This(), index: usize) []const u8 {
        const icon_url = self.cache.items(.icon_url)[index];
        return self.url_string_bytes.items[icon_url.start..icon_url.end];
    }

    pub fn get_id_from_url(self: *const @This(), url: []const u8) ?types.IconRender.ID {
        for (self.cache.items(.icon_url), 0..) |icon_url_loc, i| {
            const icon_url = self.url_string_bytes.items[icon_url_loc.start..icon_url_loc.end];
            if (std.ascii.eqlIgnoreCase(url, icon_url)) {
                return self.cache.items(.icon_id)[i];
            }
        }

        return null;
    }

    pub fn deinit(self: *@This()) void {
        self.cache.deinit(self.allocator);
        self.url_string_bytes.deinit(self.allocator);
        self.data_string_bytes.deinit();
        self.hash_string_bytes.deinit(self.allocator);
    }
};

pub fn start_server(io: std.Io, storage: Storage, opts: types.ServeOptions) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var icon_manage: IconManage = .init(allocator, storage);
    defer icon_manage.deinit();

    var progress = std.Progress.start(io, .{});
    defer progress.end();


    var global: Global = .{
        .io = io,
        .storage = @constCast(&storage),
        .icon_manage = &icon_manage,
        .progress = progress,
        .core_count = try std.Thread.getCpuCount(),
    };
    const server_config: httpz.Config = .{
        .address = .localhost(opts.port),  
        .request = .{
            // NOTE: How many form values can be sent
            // If there are a lot of enabled tags all values might not be sent.
            .max_form_count = 100,
        },
    };
    var server = try httpz.Server(*Global).init(io, allocator, server_config, &global);
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

    router.get("/failed-requests", failed_requests_get, .{});

    router.get("/feed/:id", feed_get, .{});
    router.post("/feed/:id", feed_post, .{});
    router.post("/feed/:id/delete", feed_delete, .{});

    router.get("/public/*", public_get, .{});
    router.head("/public/*", public_head, .{});
    router.get("/icons/:filename", icons_get, .{});
    router.get("/favicon.ico", favicon_get, .{});

    if (@import("builtin").mode == .debug) {
        router.get("/sse", sse_stream, .{});
    }

    std.log.info("Server started at 'http://localhost:{d}'", .{opts.port});
    // start the server in the current thread, blocking.
    try server.listen(); 
}

fn write_pick_urls(writer: *std.Io.Writer, form_data: *httpz.key_value.StringKeyValue) !void {
    var iter = form_data.iterator();
    while (iter.next()) |kv| {
        if (mem.eql(u8, "url", kv.key)) {
            const c: std.Uri.Component = .{ .raw = mem.trim(u8, kv.value, &std.ascii.whitespace) };
            try writer.print("&url={f}", .{std.fmt.alt(c, .formatEscaped)});
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

fn write_selectors(writer: *std.Io.Writer, form_data: *httpz.key_value.StringKeyValue) !void {
    inline for (selector_names) |sel| {
        if (form_data.get(sel)) |raw| {
            const val = mem.trim(u8, raw, &std.ascii.whitespace);
            if (val.len > 0) {
                const c: std.Uri.Component = .{ .raw = val };
                try writer.print("&{s}={f}", .{sel, std.fmt.alt(c, .formatEscaped)});
            }
        }
    }
}

fn update_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    resp.status = 303;

    if (!global.is_updating) {
        global.is_updating = true;

        try App.update_feeds(req.arena, global.io, global.storage, &global.progress, null, .{}, global.core_count);
        global.is_updating = false;
    }

    resp.header("Location", "/");
}

fn failed_requests_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {

    if (try global.storage.get_feed_request_failed_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest_created, static_files_hash});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }

    resp.content_type = .HTML;

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    const tags = try global.storage.tags_all_with_ids(req.arena);
    const failed_requests = try global.storage.request_failed_all(req.arena);

    const failed_feed_opts: pages.FailedFeedsContent = .{
        .failed_requests = failed_requests,
        .icon_manage = global.icon_manage,
    };

    try pages.FailedFeedsPage.render(.{failed_feed_opts, .{
        .tags = tags
    }}, w);
    try w.flush();
}

fn feed_pick_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = global.storage;
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

    var location_arr: std.Io.Writer.Allocating = try .initCapacity(req.arena, 64);
    errdefer location_arr.deinit();
    var w_arr = location_arr.writer;

    const url_input = mem.trim(
        u8, 
        form_data.get("input-url") orelse "", 
        &std.ascii.whitespace,
    );
    if (url_input.len == 0) {
        try w_arr.print("/feed/add?error={f}", .{ UrlQueryError.url_missing });
        if (tags_input) |val| {
            const c: std.Uri.Component = .{ .raw = val };
            try w_arr.print("&input-tags={f}", .{std.fmt.alt(c, .formatEscaped)});
        }

        resp.header("Location", w_arr.buffered());
        return;
    }

    _ = std.Uri.parse(url_input) catch {
        const url_comp: std.Uri.Component = .{ .raw = url_input };
        try w_arr.print("/feed/add?error={f}&input-url={f}", .{UrlQueryError.invalid_url, std.fmt.alt(url_comp, .formatEscaped)});
        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try w_arr.print("&input-tags={f}", .{std.fmt.alt(c2, .formatEscaped)});
        }

        resp.header("Location", w_arr.buffered());
        return;
    };

    const url_picked = mem.trim(
        u8, 
        form_data.get("url-picked") orelse "",
        &std.ascii.whitespace
    );
    if (url_picked.len == 0) {
        const url_comp: std.Uri.Component = .{ .raw = url_input };
        try w_arr.print("/feed/pick?error={f}&input-url={f}", .{UrlQueryError.pick_url, std.fmt.alt(url_comp, .formatEscaped)});
        if (tags_input) |val| {
            const c: std.Uri.Component = .{ .raw = val };
            try w_arr.print("&input-tags={f}", .{std.fmt.alt(c, .formatEscaped)});
        }
        try write_pick_urls(&w_arr, form_data);
        try write_selectors(&w_arr, form_data);

        resp.header("Location", w_arr.buffered());
        return;
    }

    const is_html_feed = mem.eql(u8, "html", url_picked);

    if (!is_html_feed) {
        _ = std.Uri.parse(url_picked) catch {
            const url_comp: std.Uri.Component = .{ .raw = url_picked };
            try w_arr.print("/feed/pick?error={f}&input-url={f}", .{UrlQueryError.invalid_url, std.fmt.alt(url_comp, .formatEscaped)});
            if (tags_input) |val| {
                const c2: std.Uri.Component = .{ .raw = val };
                try w_arr.print("&input-tags={f}", .{std.fmt.alt(c2, .formatEscaped)});
            }

            try write_pick_urls(&w_arr, form_data);
            try write_selectors(&w_arr, form_data);

            resp.header("Location", w_arr.buffered());
            return;
        };
    }

    var feed_url = if (is_html_feed) url_input else url_picked;

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
        try w_arr.print("/feed/pick?feed-exists={d}&input-url={f}", .{feed_id, std.fmt.alt(url_comp, .formatEscaped)});

        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try w_arr.print("&input-tags={f}", .{std.fmt.alt(c2, .formatEscaped)});
        }

        try write_pick_urls(&w_arr, form_data);
        try write_selectors(&w_arr, form_data);
        try w_arr.print("&pick-index={}", .{pick_index});

        resp.header("Location", w_arr.buffered());
        return;
    }

    const selector_container = mem.trim(
        u8, 
        form_data.get("selector-container") orelse "",
        &std.ascii.whitespace,
    );
    if (is_html_feed and selector_container.len == 0) {
        const url_comp: std.Uri.Component = .{ .raw = url_input };
        try w_arr.print("/feed/pick?error={f}&input-url={f}", .{UrlQueryError.empty_selector, std.fmt.alt(url_comp, .formatEscaped)});
        try write_pick_urls(&w_arr, form_data);
        try write_selectors(&w_arr, form_data);
        try w_arr.print("&pick-index={}", .{pick_index});

        resp.header("Location", w_arr.buffered());
        return;
    }

    var buffer_header: [1024]u8 = undefined;
    var buffer_url: [1024]u8 = undefined;
    var a_writer: std.Io.Writer.Allocating = try .initCapacity(req.arena, 8 * 1024);
    errdefer a_writer.deinit();

    const uri = try std.Uri.parse(feed_url);
    if (uri.host) |host| {
        const host_str = util.uri_component_val(host);
        const rules = try db.get_rules_for_host(req.arena, host_str);
        defer req.arena.free(rules);
        if (try AddRule.find_rule_match(uri, rules)) |rule_match| {
            std.log.info("Found matching rule. Using rule to transform url.", .{});
            feed_url = try AddRule.transform_rule_match(req.arena, uri, rule_match);
        }
    }

    var client = http_client.init(global.io, req.arena);
    defer client.deinit();
    const feed_uri = try std.Uri.parse(feed_url);
    const feed_options = try client.fetch(req.arena, feed_uri, .{
        .buffer_header = &buffer_header,
    }) orelse {
        std.log.warn("Request to '{s}' returned with status code {}", .{feed_url, client.response.?.head.status});
        return;
    };

    var add_opts: Storage.AddOptions = .{ .feed_opts = feed_options };
    add_opts.feed_opts.feed_url = try std.Uri.parse(try client.get_url_slice(&buffer_url));

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
        add_opts.feed_opts.icon = http_client.fetch_icon(global.io, req.arena, client.get_uri(), .{
            .html_body = if (feed_options.content_type == .html) feed_options.body else null,
        }) catch |err| blk: {
            std.log.warn("Failed to fetch icon with input url '{f}'. Error: {}", .{add_opts.feed_opts.feed_url, err});
            break :blk null;
        };
    }
    
    var parsing: parse = .init(global.io, add_opts.feed_opts.body);

    const parsed_feed = try parsing.parse(req.arena, html_opts, .{
        .feed_url = add_opts.feed_opts.feed_url,
    });
  
    const feed = try db.addFeed(parsed_feed, add_opts);

    if (feed.icon_id.is_valid()) {
        const icon = add_opts.feed_opts.icon.?;
        _ = global.icon_manage.add(.{
            .icon_id = feed.icon_id,
            .icon_url = icon.url,
            .icon_data = icon.data,
            .etag_or_last_modified_or_hash = icon.etag_or_last_modified_or_hash,
        }) catch |err| {
            std.log.warn("Server failed to cache new feed's icon. Error: {}", .{err});
        };
    }

    const feed_id = feed.feed_id;

    if (tags_input) |raw| {
        errdefer {
            // TODO: fix due to zig changes
            // std.log.err("Failed to add tags for new feed '{f}'. Error: {}", .{add_opts.feed_opts.feed_url, err});
            std.log.err("Failed to add tags for new feed '{f}'.", .{add_opts.feed_opts.feed_url});
        }

        var iter = mem.splitScalar(u8, raw, ',');
        const cap = mem.count(u8, raw, ",") + 1;
        var tags_arr = try std.ArrayList([]const u8).initCapacity(req.arena, cap);
        defer tags_arr.deinit(req.arena);

        while (iter.next()) |tag| {
            const trimmed = mem.trim(u8, tag, &std.ascii.whitespace);
            tags_arr.appendAssumeCapacity(trimmed);
        }

        try db.tags_add(tags_arr.items);
        const tags_ids_buf = try req.arena.alloc(types.SqliteId, tags_arr.items.len);
        const tags_ids = try db.tags_ids(tags_arr.items, tags_ids_buf);
        try db.tags_feed_add(feed_id, tags_ids);
    }

    try w_arr.print("/feed/add?success={d}", .{feed_id});
    resp.header("Location", w_arr.buffered());
}

fn feed_pick_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    var query = try req.query();

    const url_raw = query.get("input-url") orelse {
        const redirect = comptimePrint("/feed/add?error={f}", .{ UrlQueryError.url_missing });
        resp.header("Location", redirect);
        return;
    }; 

    const url = mem.trim(u8, url_raw, &std.ascii.whitespace);
    if (url.len == 0) {
        const redirect = comptimePrint("/feed/add?error={f}", .{ UrlQueryError.url_missing });
        resp.header("Location", redirect);
        return;
    }
        
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    const tags = try global.storage.tags_all_with_ids(req.arena);

    const query_picked_index = if (query.get("pick-index")) |raw|
        std.fmt.parseInt(u32, raw, 10) catch 0
        else 0;

    var feed_pick_opts: pages.FeedPickOpts = .{
        .input_tags = query.get("input-tags") orelse "",
        .input_url = url,
        .query = query,
        .writer = w,
        .query_picked_index = query_picked_index,
        .is_html_checked = blk: {
            var count: u32 = 0;
            for (query.keys) |key| {
                count += @intFromBool(std.mem.eql(u8, "url", key));
            }
            break :blk count == query_picked_index;
        },
        .html_opts = .{
            .selector_container = selector_value(query, "selector-container"),
            .selector_link = selector_value(query, "selector-link"),
            .selector_heading = selector_value(query, "selector-heading"),
            .selector_date = selector_value(query, "selector-date"),
            .date_format = selector_value(query, "feed-date-format"),
        },
    };

    if (query.get("feed-exists")) |raw_value| {
        feed_pick_opts.query_feed_exists = std.fmt.parseUnsigned(u64, raw_value, 10);
    } else if (query.get("error")) |value| {
        feed_pick_opts.query_error = UrlQueryError.from_string(value);
    }

    try pages.FeedPickPage.render(.{feed_pick_opts, .{
        .tags = tags
    }}, w);
    try w.flush();
}

fn selector_value(query: *httpz.key_value.StringKeyValue, key: []const u8) []const u8 {
    if (query.get(key)) |raw| {
        const value = mem.trim(u8, raw, &std.ascii.whitespace);
        if (value.len > 0) {
            return value;
        }
    }
    return "";
}

// TODO: on error redirect back to previous page?
fn feed_add_post(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = global.storage;

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

    var location_arr: std.Io.Writer.Allocating = try .initCapacity(req.arena, 64);
    errdefer location_arr.deinit();
    var w_arr = &location_arr.writer;

    var url_tmp: ?[]const u8 = null;
   
    if (url_input) |url_raw| {
        const url = mem.trim(u8, url_raw, &std.ascii.whitespace);
        if (url.len == 0) {
            const location = blk: {
                if (tags_input) |val| {
                    const c: std.Uri.Component = .{ .raw = val };
                    try w_arr.print("/feed/add?error={f}&input-tags={f}", .{UrlQueryError.url_missing, std.fmt.alt(c, .formatEscaped)});
                    break :blk w_arr.buffered();
                }
                break :blk comptimePrint("/feed/add?error={f}", .{ UrlQueryError.url_missing });
            };

            resp.header("Location", location);
            return;
        }

        _ = std.Uri.parse(url) catch {
            const url_comp: std.Uri.Component = .{ .raw = url };
        
            try w_arr.print("/feed/add?error={f}&input-url={f}", .{UrlQueryError.invalid_url, std.fmt.alt(url_comp, .formatEscaped)});
            if (tags_input) |val| {
                const tags_comp: std.Uri.Component = .{ .raw = val };
                try w_arr.print("&input-tags={f}", .{std.fmt.alt(tags_comp, .formatEscaped)});
            }

            resp.header("Location", w_arr.buffered());
            return;
        };
        url_tmp = url;
    }

    var feed_url = mem.trim(u8, url_tmp.?, &std.ascii.whitespace);

    if (try db.get_feed_id_with_url(feed_url)) |feed_id| {
        const url_comp: std.Uri.Component = .{ .raw = feed_url };
        try w_arr.print("/feed/add?feed-exists={d}&input-url={f}", .{feed_id, std.fmt.alt(url_comp, .formatEscaped)});
        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try w_arr.print("&input-tags={f}", .{std.fmt.alt(c2, .formatEscaped)});
        }

        resp.header("Location", w_arr.buffered());
        return;
    }

    var buffer_header: [1024]u8 = undefined;
    var buffer_url: [1024]u8 = undefined;
    var a_writer: std.Io.Writer.Allocating = try .initCapacity(req.arena, 8 * 1024);
    errdefer a_writer.deinit();

    const uri = try std.Uri.parse(feed_url);
    if (uri.host) |host| {
        const host_str = util.uri_component_val(host);
        const rules = try db.get_rules_for_host(req.arena, host_str);
        defer req.arena.free(rules);
        if (try AddRule.find_rule_match(uri, rules)) |rule_match| {
            std.log.info("Found matching rule. Using rule to transform url.", .{});
            feed_url = try AddRule.transform_rule_match(req.arena, uri, rule_match);
        }
    }
    
    var client = http_client.init(global.io, req.arena);
    defer client.deinit();
    const feed_uri = try std.Uri.parse(feed_url);
    const feed_options = try client.fetch(req.arena, feed_uri, .{
        .buffer_header = &buffer_header,
    }) orelse {
        std.log.warn("Request to '{s}' returned with status code {}", .{feed_url, client.response.?.head.status});
        return;
    };

    if (feed_options.content_type == .html) {
        const url_comp: std.Uri.Component = .{ .raw = feed_url };
        try w_arr.print("/feed/pick?input-url={f}", .{
            std.fmt.alt(url_comp, .formatEscaped)
        });
        if (tags_input) |val| {
            const c2: std.Uri.Component = .{ .raw = val };
            try w_arr.print("&input-tags={f}", .{std.fmt.alt(c2, .formatEscaped)});
        }
        const html_parsed = try html.parse_html(req.arena, feed_options.body);
        for (html_parsed.links) |link| {
            try w_arr.writeAll("&url=");
            const url_final = try client.get_url_slice(&buffer_url);
            const uri_final = try std.Uri.parse(url_final);
            try feed_types.resolve_and_write_url(w_arr, link.link, uri_final);
        }
        resp.header("Location", w_arr.buffered());
        return;
    }

    var add_opts: Storage.AddOptions = .{ .feed_opts = feed_options };
    add_opts.feed_opts.feed_url = try std.Uri.parse(try client.get_url_slice(&buffer_url));

    // TODO: fetch and add favicon in another thread?
    // probably need to copy (alloc) feed_url because request might clean (dealloc) up
    if (add_opts.feed_opts.icon == null) {
        add_opts.feed_opts.icon = http_client.fetch_icon(global.io, req.arena, client.get_uri(), .{
            .html_body = if (feed_options.content_type == .html) feed_options.body else null,
        }) catch |err| blk: {
            std.log.warn("Failed to fetch icon with input url '{f}'. Error: {}", .{add_opts.feed_opts.feed_url, err});
            break :blk null;
        };
    }

    var parsing: parse = .init(global.io, add_opts.feed_opts.body);

    const parsed_feed = try parsing.parse(req.arena, null, .{
        .feed_url = add_opts.feed_opts.feed_url,
    });

    const feed = try db.addFeed(parsed_feed, add_opts);

    if (feed.icon_id.is_valid()) {
        const icon = add_opts.feed_opts.icon.?;
        _ = global.icon_manage.add(.{
            .icon_id = feed.icon_id,
            .icon_url = icon.url,
            .icon_data = icon.data,
            .etag_or_last_modified_or_hash = icon.etag_or_last_modified_or_hash,
        }) catch |err| {
            std.log.warn("Server failed to cache new feed's icon. Error: {}", .{err});
        };
    }

    const feed_id = feed.feed_id;

    if (tags_input) |raw| {
        // TODO: fix due to zig changes
        errdefer {
            // std.log.err("Failed to add tags for new feed '{f}'. Error: {}", .{add_opts.feed_opts.feed_url, err});
            std.log.err("Failed to add tags for new feed '{f}'.", .{add_opts.feed_opts.feed_url});
        }

        var iter = mem.splitScalar(u8, raw, ',');
        const cap = mem.count(u8, raw, ",") + 1;
        var tags_arr = try std.ArrayList([]const u8).initCapacity(req.arena, cap);
        defer tags_arr.deinit(req.arena);

        while (iter.next()) |tag| {
            const trimmed = mem.trim(u8, tag, &std.ascii.whitespace);
            tags_arr.appendAssumeCapacity(trimmed);
        }

        try db.tags_add(tags_arr.items);
        const tags_ids_buf = try req.arena.alloc(types.SqliteId, tags_arr.items.len);
        const tags_ids = try db.tags_ids(tags_arr.items, tags_ids_buf);
        try db.tags_feed_add(feed_id, tags_ids);
    }

    try w_arr.print("/feed/add?success={d}", .{feed_id});
    resp.header("Location", w_arr.buffered());
}

fn feed_add_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = global.storage;

    if (try db.get_tags_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest_created, static_files_hash});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    const tags = try global.storage.tags_all_with_ids(req.arena);
    defer req.arena.free(tags);

    var query = try req.query();

    var feed_add_opts: pages.FeedAddOpts = .{
        .input_url = query.get("input-url") orelse "",
        .input_tags = query.get("input-tags") orelse "",
    };

    if (query.get("success")) |id_raw| {
        feed_add_opts.query_success = std.fmt.parseUnsigned(u64, id_raw, 10);
    } else if (query.get("feed-exists")) |raw_value| {
        feed_add_opts.query_feed_exists = std.fmt.parseUnsigned(u64, raw_value, 10);
    } else if (query.get("error")) |value| {
        feed_add_opts.query_error = UrlQueryError.from_string(value);
    }

    try pages.FeedAddPage.render(.{feed_add_opts, .{
        .tags = tags
    }}, w);
    try w.flush();
}

fn feed_delete(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const feed_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const feed_id_u64 = std.fmt.parseUnsigned(u64, feed_id_raw, 10) catch return error.InvalidIdParam;
    const feed_id: types.Feed.ID = @enumFromInt(feed_id_u64);

    const db = global.storage;
    resp.status = 301;
    db.deleteFeed(feed_id) catch {
        // On failure redirect to feed page. Display error message
        const url_redirect = try std.fmt.allocPrint(req.arena, "/feed/{d}/?error={f}", .{feed_id, UrlQueryError.delete});
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
    const feed_id_u64 = std.fmt.parseUnsigned(u64, feed_id_raw, 10) catch return error.InvalidIdParam;
    const feed_id: types.Feed.ID = @enumFromInt(feed_id_u64);

    const title = form_data.get("title") orelse return error.MissingFormFieldPageTitle;
    const page_url = form_data.get("page_url") orelse return error.MissingFormFieldPageUrl;
    const icon_url = form_data.get("icon_url") orelse return error.MissingFormFieldIconUrl;

    var tags: std.ArrayList([]const u8) = .empty;
    defer tags.deinit(req.arena);
    for (form_data.keys[0..form_data.len], form_data.values[0..form_data.len]) |key, value| {
        if (mem.eql(u8, "tag", key)) {
            try tags.append(req.arena, value);
        }
    }

    const new_tags = form_data.get("new_tags") orelse return error.MissingFormFieldNewTags;
    var tags_iter = mem.splitScalar(u8, new_tags, ',');
    while (tags_iter.next()) |tag_raw| {
        const tag = mem.trim(u8, tag_raw, &std.ascii.whitespace);
        if (tag.len > 0) {
            try tags.append(req.arena, tag);
        }
    }

    const db = global.storage;

    const icon_url_trimmed = mem.trim(u8, icon_url, &std.ascii.whitespace);
    if (icon_url_trimmed.len >= icon_input_max_size) {
        const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error={f}", .{req.url.path, UrlQueryError.icon_too_large});
        resp.header("Location", url_redirect);
        return;
    }

    const icon_id: types.IconRender.ID = blk: {
        if (icon_url_trimmed.len == 0) {
            break :blk .unassigned;
        }

        if (util.is_url(icon_url_trimmed)) {
            if (global.icon_manage.get_id_from_url(icon_url_trimmed)) |icon_id| {
                break :blk icon_id;
            }

            // is url
            var req_http = http_client.init(global.io, req.arena);
            defer req_http.deinit();

            var buffer_header: [1024]u8 = undefined;
            var a_writer: std.Io.Writer.Allocating = try .initCapacity(req.arena, 8 * 1024);
            errdefer a_writer.deinit();

            const icon_uri = try std.Uri.parse(icon_url_trimmed);
            const cache_control = req_http.fetch_image(&a_writer.writer, req.arena, icon_uri, .{
                .buffer_header = &buffer_header,
            }) catch break :blk .unassigned;
            const resp_body = a_writer.writer.buffered();

            const cache_value = cache_control.?.etag orelse cache_control.?.last_modified;
            const icon = feed_types.Icon.init(req_http.get_uri(), resp_body, cache_value);
            const icon_id = try db.icon_upsert(icon);
            _ = try global.icon_manage.add(.{
                .icon_id = icon_id,
                .icon_data = icon.data,
                .icon_url = icon.url,
                .etag_or_last_modified_or_hash = icon.etag_or_last_modified_or_hash,
            });
            break :blk icon_id;
        } else if (util.is_inline_svg(icon_url_trimmed)) {
            // Only inline svg allowed for icon
            const data = std.Uri.percentDecodeInPlace(@constCast(icon_url_trimmed));
            if (global.icon_manage.get_id_from_url(icon_url_trimmed)) |icon_id| {
                break :blk icon_id;
            }

            const page_uri = try std.Uri.parse(page_url);
            const icon = feed_types.Icon.init(page_uri, data, null);
            const icon_id = try db.icon_upsert(icon);
            _ = try global.icon_manage.add(.{
                .icon_id = icon_id,
                .icon_data = icon.data,
                .icon_url = icon.url,
                .etag_or_last_modified_or_hash = icon.etag_or_last_modified_or_hash,
            });

            break :blk icon_id;
        } else {
            std.log.info("User entered invalid icon input: '{s}'", .{icon_url_trimmed});
            // TODO: cancel updating feed?
            // TODO: make use aware of mistake
        }

        break :blk .unassigned;
    };

    resp.status = 303;
    const fields: Storage.FeedFields = .{
        .feed_id = feed_id,
        .title = title,
        .page_url = page_url,
        .icon_id = icon_id,
        .tags = tags.items,
    };
    db.update_feed_fields(req.arena, fields) catch |err| {
        std.log.err("Failed to update feed. Error {}", .{err});
        const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error={f}", .{req.url.path, UrlQueryError.feed});
        resp.header("Location", url_redirect);
        return;
    };

    if (try db.html_selector_has(feed_id)) {
        const selector_item = get_field(form_data, "html-item-selector") catch return error.MissingFormFieldHtmlItemSelector;
        if (selector_item == null) {
            const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error={f}", .{req.url.path, UrlQueryError.item_selector});
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

        db.html_selector_add(feed_id, update_fields) catch {
            const url_redirect = try std.fmt.allocPrint(req.arena, "{s}?error={f}", .{req.url.path, UrlQueryError.html});
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

fn feed_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = global.storage;
    const id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const feed_id_u64 = std.fmt.parseUnsigned(u64, id_raw, 10) catch return error.InvalidIdParam;
    const feed_id: types.Feed.ID = @enumFromInt(feed_id_u64);
    // TODO: maybe can also get 'last_update' and 'next_update' with one query?
    const feed = db.feed_with_id(req.arena, feed_id) catch {
        return error.DatabaseFailure;
    } orelse {
        resp.status = 404;
        resp.body = "Feed not found";
        return;
    };

    resp.content_type = .HTML;

    if (try db.get_latest_feed_change(feed_id)) |latest| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest, static_files_hash});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }

    const tags = try global.storage.tags_all_with_ids(req.arena);

    const feed_tags = try db.feed_tags(req.arena, feed.feed_id);
    const items = try db.feed_items_with_feed_id(req.arena, feed.feed_id);

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    const query_kv = try req.query();

    var buf_tag: [128]u8 = undefined;
    var write_title: std.Io.Writer = .fixed(&buf_tag);
    write_title.writeAll("Feed - ") catch unreachable;
    try write_title.writeAll(if (feed.title) |val| val else "[no-title]");

    const now_date = Datetime.nowUTC(global.io);
    const now_sec: i64 = @intCast(now_date.toUnix(.second));

    var feed_opts: pages.FeedOpts = .{
        .icon_manage = global.icon_manage,
        .feed = feed,
        .feed_tags = feed_tags,
        .feed_items = items,
        .head_title = write_title.buffered(),
        .last_update = try db.feed_last_update(feed.feed_id),
        .next_update = try db.next_update_feed(feed.feed_id),
        .now_sec = now_sec,
        .failed_requests = try db.request_failed_slice(req.arena, feed.feed_id),
        .query_success = query_kv.get("success") != null,
    };

    if (query_kv.get("error")) |error_value| {
        feed_opts.query_error = UrlQueryError.from_string(error_value);
    }

    const page_url = feed.page_url orelse std.Uri{.scheme = ""};

    if (std.meta.eql(page_url, feed.feed_url)) {
        feed_opts.html_opts = try db.html_selector_get(req.arena, feed.feed_id);
    }
    
    try pages.FeedPage.render(.{feed_opts, .{
        .tags = tags
    }}, w);
    try w.flush();
}

fn get_file(io: std.Io, allocator: std.mem.Allocator, comptime path: []const u8) ![]const u8 {
    if (builtin.mode == .debug) {
        var buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "src/{s}", .{path});
        var file = try std.Io.Dir.cwd().openFile(io, p, .{});
        defer file.close(io);
        var reader_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &reader_buf);
        return try reader.interface.allocRemaining(allocator, .unlimited);
    } else {
        return @embedFile(path);
    }
}

fn public_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    var src: ?[]const u8 = null;
    const prefix_dir = if (builtin.mode == .debug) "server" else "server/dist";

    if (mem.endsWith(u8, req.url.path, "main.js")) {
        src = try get_file(global.io, req.arena, prefix_dir ++ "/main.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "relative-time.js")) {
        src = try get_file(global.io, req.arena, prefix_dir ++ "/relative-time.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "main.css")) {
        src = try get_file(global.io, req.arena, prefix_dir ++ "/main.css");
        resp.content_type = .CSS;
    }

    if (builtin.mode == .debug) {
        if (mem.endsWith(u8, req.url.path, "style.css")) {
            src = try get_file(global.io, req.arena, prefix_dir ++ "/style.css");
            resp.content_type = .CSS;
        } else if (mem.endsWith(u8, req.url.path, "kelp.css")) {
            src = try get_file(global.io, req.arena, prefix_dir ++ "/kelp.css");
            resp.content_type = .CSS;
        } else if (mem.endsWith(u8, req.url.path, "main.css")) {
            src = try get_file(global.io, req.arena, prefix_dir ++ "/main.css");
            resp.content_type = .CSS;
        } else if (mem.endsWith(u8, req.url.path, "reload.js")) {
            src = try get_file(global.io, req.arena, prefix_dir ++ "/reload.js");
            resp.content_type = .JS;
        }
    }

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    if (src) |body| {
        resp.header("Cache-control", "public,max-age=31536000,immutable");

        var compress_opt = try compress_init(req, resp, &buf);
        var w = if (compress_opt) |*c| &c.writer else resp.writer();
        try w.writeAll(body);
        try w.flush();
    }
}

fn get_file_last_modified(io: std.Io, comptime path: []const u8) !i64 {
    var buf: [256]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "src/{s}", .{path});
    const file = try std.Io.Dir.cwd().openFile(io, p, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return stat.mtime.toSeconds();
}

fn public_head(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    var last_modified: ?i64 = null;
    if (mem.endsWith(u8, req.url.path, "main.js")) {
        last_modified = try get_file_last_modified(global.io, "server/main.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "relative-time.js")) {
        last_modified = try get_file_last_modified(global.io, "server/relative-time.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "reload.js")) {
        last_modified = try get_file_last_modified(global.io, "server/reload.js");
        resp.content_type = .JS;
    } else if (mem.endsWith(u8, req.url.path, "style.css")) {
        last_modified = try get_file_last_modified(global.io, "server/style.css");
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
        const file_type = global.icon_manage.cache.items(.file_type)[index];
        if (iter.next()) |file_type_raw| if (IconFileType.from_string(file_type_raw)) |ft_req| {
            if (file_type != ft_req) {
                std.log.warn("Request icon file type and current icon type don't match. Request icon type: {s}. Current icon type: {}.", .{file_type_raw, ft_req});
                break :blk;
            }
        };

        resp.header("Content-Type", file_type.to_content_type());
        resp.header("Cache-control", "public,max-age=31536000,immutable");
        if (file_type == .svg) {
            resp.header("Content-Encoding", "gzip");
        }

        const body = body: {
            const data = global.icon_manage.get_data_string_by_index(index);
            if (util.is_data(data)) {
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

const gzip_header_size = 16;
fn compress_init(req: *httpz.Request, resp: *httpz.Response, buf: []u8) !?std.compress.flate.Compress { 
    if (!has_encoding(req, "gzip")) {
        return null;
    }

    // NOTE: make space for gzip header bytes.
    // Because I will be reusing Response.Writer buffer.
    // _ = try resp.writer().splatByte(' ', gzip_header_size);
    resp.header("Content-Encoding", "gzip");
    try resp.buffer.ensureTotalCapacity(8 * 1024);
    return try std.compress.flate.Compress.init(resp.writer(), buf, .gzip, .default);
}

fn latest_added_head(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = global.storage;

    if (try db.get_latest_change()) |latest_created| {
        const countdown = db.next_update_timestamp() catch 0 orelse 0;
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}-{x}\"", .{latest_created, countdown, static_files_hash});
        _ = resp_cache(req, resp, etag_out, .{});
    }
    
    resp.content_type = .HTML;
}

fn latest_added_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = global.storage;

    if (try db.get_latest_change()) |latest_created| {
        const countdown = db.next_update_timestamp() catch 0 orelse 0;
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}-{x}\"", .{latest_created, countdown, static_files_hash});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }
    
    resp.content_type = .HTML;

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    const tags = try global.storage.tags_all_with_ids(req.arena);

    const query = try req.query();

    const next_update_ts = try db.next_update_timestamp();
    const items = try db.get_items_latest_added(req.arena);

    const now_date = Datetime.nowUTC(global.io);
    const now_sec: i64 = @intCast(now_date.toUnix(.second));

    var home_opts = pages.HomeContent{
        .next_update_ts = next_update_ts,
        .items = items,
        .now_sec = now_sec,
        .icon_manage = global.icon_manage,
    };

    if (query.get("msg")) |value| {
        home_opts.display_feed_delete_msg = mem.eql(u8, "delete", value);
    }

    if (items.len > 0) {
        const cookie_last_item_ts = get_cookie_value(req)
            orelse std.math.maxInt(i64);
        const current_last_item_ts = items[0].created_timestamp;
        if (current_last_item_ts > cookie_last_item_ts
            or cookie_last_item_ts == std.math.maxInt(i64)) {
            const seconds_in_4_days = 4 * std.time.s_per_day;
            const cookie_value = try std.fmt.allocPrint(
                req.arena,
                "{s}={d}; Max-Age={d}",
                .{cookie_key, current_last_item_ts, seconds_in_4_days},
            );

            resp.headers.add("Set-Cookie", cookie_value);
        }

        var ids_al = try std.ArrayList(types.Feed.ID).initCapacity(req.arena, items.len);
        defer ids_al.deinit(req.arena);
        for (items) |item| {
            if (!mem.containsAtLeastScalar(types.Feed.ID, ids_al.items, item.feed_id, 1)) {
                ids_al.appendAssumeCapacity(item.feed_id);
            }
        }

        home_opts.failed_requests = try db.request_failed_ids(req.arena);
        home_opts.feeds = try db.get_feeds_with_ids(req.arena, ids_al.items);
        home_opts.cookie_last_item_ts = cookie_last_item_ts;
    }

    try pages.HomePage.render(.{home_opts, .{
        .tags = tags
    }}, w);
    try w.flush();
}

fn tag_delete(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const tag_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const tag_id_u64 = std.fmt.parseUnsigned(u64, tag_id_raw, 10) catch return error.InvalidIdParam;

    const db = global.storage;
    resp.status = 301;
    const tag_id: types.SqliteId = @enumFromInt(tag_id_u64);
    const tag = db.tag_with_id(req.arena, tag_id) catch {
        const redirect = comptimePrint("/tags?error={f}", .{ UrlQueryError.delete });
        resp.header("Location", redirect);
        return;
    } orelse {
        const redirect = comptimePrint("/tags?error={f}", .{ UrlQueryError.delete });
        resp.header("Location", redirect);
        return;
    };

    db.tags_remove_with_id(tag_id) catch {
        const redirect = comptimePrint("/tags?error={f}", .{ UrlQueryError.delete });
        resp.header("Location", redirect);
        return;
    };

    var location_arr: std.Io.Writer.Allocating = try .initCapacity(req.arena, 64);
    errdefer location_arr.deinit();
    try location_arr.writer.print("/tags?success={s}", .{tag.name});
    resp.header("Location", location_arr.writer.buffered());
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

    const db = global.storage;
    resp.status = 301;

    var location_arr: std.Io.Writer.Allocating = try .initCapacity(req.arena, 64);
    errdefer location_arr.deinit();
    const tag_name_form = form_data.get("tag-name") orelse {
        const fmt = comptimePrint("/tag/{{d}}/edit?error={f}", .{ UrlQueryError.invalid_form });
        try location_arr.writer.print(fmt, .{tag_id});
        resp.header("Location", location_arr.writer.buffered());
        return;
    };

    const tag_id_form_raw = form_data.get("tag-id") orelse {
        const fmt = comptimePrint("/tag/{{d}}/edit?error={f}", .{ UrlQueryError.invalid_form });
        try location_arr.writer.print(fmt, .{tag_id});
        resp.header("Location", location_arr.writer.buffered());
        return;
    };
    const tag_id_form_u64 = std.fmt.parseUnsigned(u64, tag_id_form_raw, 10) catch return error.InvalidIdParam;
    const tag_id_form: types.SqliteId = @enumFromInt(tag_id_form_u64);

    try db.tag_update(.{ .tag_id = tag_id_form, .name = tag_name_form });

    try location_arr.writer.print("/tag/{d}/edit?success=", .{tag_id});
    resp.header("Location", location_arr.writer.buffered());
}

fn tag_edit(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const tag_id_raw = req.params.get("id") orelse return error.FailedToParseIdParam;
    const tag_id_u64 = std.fmt.parseUnsigned(u64, tag_id_raw, 10) catch return error.InvalidIdParam;
    const tag_id: types.SqliteId = @enumFromInt(tag_id_u64);

    const db = global.storage;

    const tag = try db.tag_with_id(req.arena, tag_id) orelse {
        resp.status = 301;
        const redirect = comptimePrint("/tags?error={f}", .{ UrlQueryError.missing });
        resp.header("Location", redirect);
        return;
    };

    if (try db.get_tags_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest_created, static_files_hash});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }

    resp.content_type = .HTML;

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    var buf_tag: [512]u8 = undefined;
    var write_tag: std.Io.Writer = .fixed(&buf_tag);
    try write_tag.print("Edit tag: {s}", .{tag.name});

    var tag_edit_opts: pages.TagEditOpts = .{
        .title = write_tag.buffered(),
        .tag = tag,
    };

    const tags = try global.storage.tags_all_with_ids(req.arena);
    
    const query_kv = try req.query();
    if (query_kv.get("success")) |_| {
        tag_edit_opts.query_is_success = true;
    } else if (query_kv.get("error")) |val| {
        tag_edit_opts.query_error = UrlQueryError.from_string(val);
    }

    try pages.TagEditPage.render(.{tag_edit_opts, .{
        .tags = tags
    }}, w);
    try w.flush();
}

fn tags_get(global: *Global, req: *httpz.Request, resp: *httpz.Response) !void {
    const db = global.storage;

    if (try db.get_tags_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest_created, static_files_hash});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }

    resp.content_type = .HTML;

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    const query_kv = try req.query();
    const tags = try global.storage.tags_all_with_ids(req.arena);

    const tags_opts: pages.TagsContent = .{
        .query_is_success = query_kv.get("success") != null,
        .query_error = blk: {
            const value = query_kv.get("error") orelse break :blk null;
            break :blk UrlQueryError.from_string(value);
        },
    };

    try pages.TagsPage.render(.{tags_opts, .{
        .tags = tags
    }}, w);
    try w.flush();
}

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
    const db = global.storage;

    if (try db.get_latest_change()) |latest_created| {
        const etag_out = try std.fmt.allocPrint(req.arena, "\"{x}-{x}\"", .{latest_created, static_files_hash});
        if (resp_cache(req, resp, etag_out, .{})) {
            resp.status = 304;
            return;
        }
    }
    
    resp.content_type = .HTML;

    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress_opt = try compress_init(req, resp, &buf);
    var w: *std.Io.Writer = if (compress_opt) |*c| &c.writer else resp.writer();

    const query = try req.query();
    const search_value = if (query.get("search")) |val| mem.trim(u8, val, &std.ascii.whitespace) else null;

    var tags_active = try std.ArrayList(feed_types.SqliteId).initCapacity(req.arena, query.len);
    defer tags_active.deinit(req.arena);

    const tags = try db.tags_all_with_ids(req.arena);

    for (query.keys[0..query.len], query.values[0..query.len]) |key, value| {
        if (!mem.eql(u8, "tag", key)) continue;

        for (tags) |tag| {
            if (mem.eql(u8, value, tag.name)) {
                tags_active.appendAssumeCapacity(tag.tag_id);
                break;
            }
        }
    }

    const has_untagged = query.get("untagged") != null;

    const before: types.Feed.ID = before: {
        if (query.get("before")) |value| {
            const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                if (std.fmt.parseInt(u64, trimmed, 10)) |feed_id_u64| {
                    break :before @enumFromInt(feed_id_u64);
                } else |_| {}
            }
        }
        break :before .unassigned;
    };

    const feeds = blk: {
        const after: types.Feed.ID = after: {
            if (before == .unassigned) {
                if (query.get("after")) |value| {
                    const trimmed = mem.trim(u8, value, &std.ascii.whitespace);
                    if (trimmed.len > 0) {
                        if (std.fmt.parseInt(u64, trimmed, 10)) |feed_id_u64| {
                            break :after @enumFromInt(feed_id_u64);
                        } else |_| {}
                    }
                }
            }
            break :after .unassigned;
        };

        break :blk try db.feeds_search_complex(req.arena, .{ 
            .search = search_value, 
            .tags = tags_active.items, 
            .before = before,
            .after = after, 
            .has_untagged = has_untagged,
        });
    };

    const feed_ids = blk: {
        var ids_arr: std.ArrayList(feed_types.Feed.ID) = try .initCapacity(req.arena, feeds.len);
        for (feeds) |feed| {
            ids_arr.appendAssumeCapacity(feed.feed_id);
        }
         break :blk ids_arr.items;
    };
    defer req.arena.free(feed_ids);

    var feeds_opts: pages.FeedsOpts = .{
        .feeds = feeds,
        .icon_manage = global.icon_manage,
    };

    if (feeds.len > 0) {
        feeds_opts.feeds_tags = try global.storage.feeds_tags(req.arena, feed_ids);
        feeds_opts.items = try db.feed_items_with_feed_ids(req.arena, feed_ids);
        feeds_opts.failed_requests = try db.request_failed_ids(req.arena);
        const now_date = Datetime.nowUTC(global.io);
        feeds_opts.now_sec = @intCast(now_date.toUnix(.second));

        // try feeds_and_items_print(w, req.arena, db, feeds, global, failed_requests);

        if (feeds.len == config.query_feed_limit) {
            const new_url_arr: std.Io.Writer.Allocating = try .initCapacity(req.arena, 128);
            // defer new_url_arr.deinit();
            var w_arr = new_url_arr.writer;

            w_arr.writeAll("/feeds?") catch unreachable;
            for (query.keys[0..query.len], query.values[0..query.len]) |key, value| {
                if (mem.eql(u8, "tag", key) or
                    mem.eql(u8, "untagged", key) or
                    mem.eql(u8, "search", key)
                ) {
                    try w_arr.writeAll(key);
                    try w_arr.writeByte('=');
                    try w_arr.writeAll(value);
                    try w_arr.writeByte('&');
                }
            }

            const str = w_arr.buffered();
            if (str[str.len - 1] == '&') {
                w_arr.end -= 1;
            }

            const is_tags_only = query.get("tags-only") != null;
            const has_prev = try db.feeds_search_has_previous(req.arena, .{
                .search = if (is_tags_only) search_value else null,
                .tags = tags_active.items, 
                .before = feeds[0].feed_id,
                .after = .unassigned, 
                .has_untagged = has_untagged,
            });
            const prev_id = if (has_prev) feeds[0].feed_id else null;
            const next_id = feeds[feeds.len - 1].feed_id;

            feeds_opts.footer = .{
                .base = w_arr.buffered(),
                .prev = prev_id,
                .next = next_id,
            };
        }
    }

    try pages.FeedsPage.render(.{feeds_opts, .{
        .tags = tags,
        .search_value = search_value orelse "",
        .has_untagged = has_untagged,
        .tags_active = tags_active.items,
    }}, w);
    try w.flush();
}

fn get_cookie_value(req: *httpz.Request) ?i64 {
    const cookie = req.headers.get("cookie") orelse return null;
    const trimmed = mem.trim(u8, cookie, &std.ascii.whitespace);
    var iter = mem.splitScalar(u8, trimmed, '=');
    const key = iter.next() orelse return null;
    if (mem.eql(u8, key, cookie_key)) {
        const value = iter.next() orelse {
            std.log.warn("Cookie key '{s}' does not have value", .{key});
            return null;
        };
        const ts = std.fmt.parseInt(i64, value, 10) catch |err| {
            std.log.warn("Failed to parse cookie value into a number. Key: '{s}'. Error: {}", .{key, err});
            return null;
        };

        return ts;
    } else {
        std.log.warn("First cookie value is not '{s}'", .{key});
    }
    return null;
}

fn sse_stream(global: *Global, _: *httpz.Request, resp: *httpz.Response) !void {
    try resp.startEventStream(StreamContext{.io = global.io}, StreamContext.handle);
}

const StreamContext = struct {
    io: std.Io,

    const files = [_][]const u8{
        "./src/server/main.css",
        "./src/server/style.css",
        "./src/server/main.js",
        "./src/server/relative-time.js",
    };

    fn file_stats(io: std.Io) ![files.len]std.Io.File.Stat {
        const cwd = std.Io.Dir.cwd();
        var result: [files.len]std.Io.File.Stat = undefined;
        for (files, 0..) |f, i| {
            result[i] = try cwd.statFile(io, f, .{});
        }

        return result;
    }

    fn hash_file_stats(input_stats: [files.len]std.Io.File.Stat) u64 {
        var hasher = std.hash.Wyhash.init(0);

        for (input_stats) |stat| {
            const key = std.mem.toBytes(stat);
            hasher.update(&key);
        }

        return hasher.final();
    }


    fn handle(ctx: StreamContext, stream: std.Io.net.Stream) void {
        std.log.info("Start SSE stream", .{});
        var buf: [32]u8 = undefined;
        var writer = stream.writer(ctx.io, &buf);
        defer stream.close(ctx.io);
        const w = &writer.interface;

        var stats = file_stats(ctx.io) catch @panic("failed to get files stats");
        var hash = hash_file_stats(stats);

        while (true) {
            ctx.io.sleep(.fromSeconds(1), .boot) catch @panic("Io.sleep was cancelled");
            stats = file_stats(ctx.io) catch return;
            const hash_new = hash_file_stats(stats);
            if (hash != hash_new) {
                hash = hash_new;
                w.writeAll("event: reload\n") catch return;
                w.print("data: {d}\n", .{hash}) catch return;
                w.writeByte('\n') catch return;
                w.flush() catch return;
                std.log.info("reload browser page", .{});
                return;
            }
        }
    }
};

pub const UrlQueryError = enum(u8) {
    delete,
    feed,
    html,
    item_selector,
    url_missing,
    invalid_url,
    pick_url,
    empty_selector,
    invalid_form,
    missing,
    unknown,
    icon_too_large,

    pub fn to_string(val: UrlQueryError) []const u8 {
        return switch(val) {
            .item_selector => "item-selector",
            .url_missing => "url-missing",
            .invalid_url => "invalid-url",
            .pick_url => "pick-url",
            .empty_selector => "empty-selector",
            .invalid_form => "invalid-form",
            .icon_too_large => "icon-too-large",
            else => @tagName(val),
        };
    }

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        try w.writeAll(self.to_string());
    }

    fn max_enum_value_len() comptime_int {
        var max_len = 0;
        for (@typeInfo(UrlQueryError).@"enum".field_names) |name| {
            if (name.len > max_len) {
                max_len = name.len;
            }
        }

        return max_len;
    }

    pub fn from_string(raw: []const u8) UrlQueryError {
        const max_len = max_enum_value_len();
        var buf: [max_len]u8 = undefined;
        std.mem.copyForwards(u8, &buf, raw);
        const val = buf[0..raw.len];
        std.mem.replaceScalar(u8, val, '-', '_');

        return std.meta.stringToEnum(UrlQueryError, val) orelse .unknown;
    }
};
