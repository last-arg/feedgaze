const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const StringHashMap = std.hash_map.StringHashMap;
const fmt = std.fmt;
const builtin = @import("builtin");
const print = std.debug.print;
const global_allocator = std.heap.page_allocator;
const Address = std.net.Address;
const Storage = @import("feed_db.zig").Storage;
const ArrayList = std.ArrayList;
const Datetime = @import("datetime").datetime.Datetime;
const url_util = @import("url.zig");
const http = @import("http.zig");
const parse = @import("parse.zig");
const f = @import("feed.zig");
const zuri = @import("zuri");
const log = std.log;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const web = @import("apple_pie");
const router = web.router;
const curl = @import("curl_extend.zig");

// Resources
// POST-REDIRECT-GET | https://andrewlock.net/post-redirect-get-using-tempdata-in-asp-net-core/
// Generating session ids | https://codeahoy.com/2016/04/13/generating-session-ids/
// https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html#references

const timestamp_fmt = "{d}.{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC";

const SessionData = struct {
    form_body: []const u8 = "",
    links_body: []const u8 = "",
};

const Session = struct {
    id: u64,
    arena: std.heap.ArenaAllocator,
    data: SessionData,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
};

pub const Sessions = struct {
    const Self = @This();
    allocator: Allocator,
    random: std.rand.Random,
    list: ArrayList(Session),
    timestamps: ArrayList(i64),

    pub fn init(allocator: Allocator) Self {
        var secret_seed: [std.rand.DefaultCsprng.secret_seed_length]u8 = undefined;
        std.crypto.random.bytes(&secret_seed);
        var csprng = std.rand.DefaultCsprng.init(secret_seed);
        const random = csprng.random();
        return .{
            .allocator = allocator,
            .random = random,
            .list = ArrayList(Session).init(allocator),
            .timestamps = ArrayList(i64).init(allocator),
        };
    }

    pub fn new(self: *Self, arena: ArenaAllocator) !*Session {
        var result = try self.list.addOne();
        try self.timestamps.append(std.time.timestamp());
        result.* = Session{
            .id = self.random.int(u64),
            .arena = arena,
            .data = .{},
        };
        return result;
    }

    pub fn remove(self: *Self, index: usize) void {
        var s = self.list.swapRemove(index);
        _ = self.timestamps.swapRemove(index);
        s.deinit();
    }

    const max_age_seconds = std.time.s_per_min * 5;
    // TODO: Better to check it on every interval.
    // At the moment event is checked every time a POST request to /feed/add is made
    pub fn cleanOld(self: *Self) void {
        if (self.timestamps.items.len == 0) return;
        const first = self.timestamps.items[0];
        const current = std.time.timestamp();
        const first_passed = current - first;
        if (first_passed > max_age_seconds) {
            var index = self.timestamps.items.len - 1;
            while (index >= 0) : (index -= 1) {
                const passed = current - self.timestamps.items[index];
                if (passed > max_age_seconds) {
                    _ = self.timestamps.swapRemove(index);
                    _ = self.list.swapRemove(index);
                }
            }
        }
    }

    pub fn getIndex(self: *Self, token: u64) ?u64 {
        for (self.list.items) |s, i| {
            if (s.id == token) return i;
        }
        return null;
    }

    pub fn deinit(self: *Self) void {
        for (self.list.items) |*session| {
            session.deinit();
        }
        self.list.deinit();
    }
};

pub const Server = struct {
    const Self = @This();
    context: Context,
    web_server: *web.Server,

    const Context = struct {
        storage: *Storage,
        allocator: Allocator,
        sessions: *Sessions,
    };

    pub fn init(allocator: Allocator, storage: *Storage, sessions: *Sessions) !Self {
        var server = try allocator.create(web.Server);
        errdefer allocator.destroy(server);
        server.* = web.Server.init();

        const context: Context = .{
            .sessions = sessions,
            .storage = storage,
            .allocator = allocator,
        };
        return Server{ .context = context, .web_server = server };
    }

    pub fn run(self: *Self) !void {
        const addr = try std.net.Address.parseIp(global.ip, global.port);
        const builder = router.Builder(*Context);
        try self.web_server.run(
            self.context.allocator,
            addr,
            &self.context,
            comptime router.Router(*Context, &.{
                builder.get("/", null, indexGet),
                builder.get("/feed/add", null, feedAddGet),
                builder.post("/feed/add", null, feedAddPost),
                builder.get("/tag/:tags", []const u8, tagGet),
            }),
        );
    }

    pub fn shutdown(self: *Self) void {
        self.web_server.shutdown();
    }

    fn feedAddGet(ctx: *Context, res: *web.Response, req: web.Request, _: ?*const anyopaque) !void {
        try res.headers.put("Content-Type", "text/html");
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const w = res.writer();

        const token: ?u64 = try getCookieToken(req);
        const session_index: ?usize = if (token) |t| ctx.sessions.getIndex(t) else null;

        try w.writeAll("<p>Home</p>");
        if (session_index == null) {
            // try w.print(form_fmt, .{ "localhost:8080/many-links.html", "tag1, tag2, tag3" });
            try w.print(form_fmt, .{ "", "" });
            return;
        }
        var session = &ctx.sessions.list.items[session_index.?];
        if (session.data.form_body.len == 0) {
            try w.writeAll("<p>There is no form data to handle</p>");
            try w.print(form_fmt, .{ "", "" });
            ctx.sessions.remove(session_index.?);
            return;
        }
        var is_submit_feed = false;
        var is_submit_feed_links = false;
        // TODO: input sanitization
        var tags: []const u8 = "";
        var url: []const u8 = "";
        var iter = mem.split(u8, session.data.form_body, "&");
        while (iter.next()) |kv| {
            var iter_kv = mem.split(u8, kv, "=");
            const key = iter_kv.next() orelse continue;
            const value = iter_kv.next() orelse continue;
            if (mem.eql(u8, "feed_url", key)) {
                url = value;
            } else if (mem.eql(u8, "tags", key)) {
                var tmp_tags = value;
                mem.replaceScalar(u8, @ptrCast(*[]u8, &tmp_tags).*, '+', ' ');
                tags = tmp_tags;
            } else if (mem.eql(u8, "submit_feed_links", key)) {
                is_submit_feed_links = true;
            } else if (mem.eql(u8, "submit_feed", key)) {
                is_submit_feed = true;
            }
        }

        if (!is_submit_feed and !is_submit_feed_links) {
            try w.writeAll("<p>Submitted form data is invalid. Can't determine what type of form was submitted.</p>");
            try w.print(form_fmt, .{ url, tags });
            ctx.sessions.remove(session_index.?);
            return;
        }

        if (is_submit_feed) {
            if (url.len == 0) {
                try w.writeAll("<p>No url entered</p>");
                try w.print(form_fmt, .{ "", tags });
                ctx.sessions.remove(session_index.?);
                return;
            }
            const valid_url = url_util.makeValidUrl(arena.allocator(), url) catch {
                try w.writeAll("<p>Invalid url entered</p>");
                try w.print(form_fmt, .{ url, tags });
                ctx.sessions.remove(session_index.?);
                return;
            };

            const resp = try http.resolveRequestCurl(&arena, valid_url, .{});
            const last_header = curl.getLastHeader(resp.headers_fifo.readableSlice(0));

            const content_type_value = curl.getHeaderValue(last_header, "content-type:") orelse {
                try w.writeAll("<p>Failed to find Content-Type</p>");
                try w.print(form_fmt, .{ url, tags });
                ctx.sessions.remove(session_index.?);
                return;
            };

            const content_type = http.ContentType.fromString(content_type_value);
            switch (content_type) {
                .html => {
                    const body = resp.body_fifo.readableSlice(0);
                    const html_page = try parse.Html.parseLinks(arena.allocator(), body);
                    const base_uri = try zuri.Uri.parse(valid_url, true);
                    const fallback_title = html_page.title orelse "<no-title>";
                    var links_html = ArrayList(u8).init(session.arena.allocator());
                    defer links_html.deinit();
                    try links_html.writer().print("<input type=\"hidden\" name=\"feed_url\" value=\"{s}\">", .{valid_url});
                    try links_html.appendSlice("<p>Pick a feed link(s) to add</p><ul>");
                    for (html_page.links) |link| {
                        const fmt_link =
                            \\<li><label>
                            \\ <input type="checkbox" name="feed_link_checkbox" value="{s}">
                            \\ <span>[{s}] {s} | {s}</span>
                            \\</label></li>
                        ;
                        const title = link.title orelse fallback_title;
                        const media_type = parse.Html.MediaType.toString(link.media_type);
                        const link_url = try url_util.makeWholeUrl(arena.allocator(), base_uri, link.href);
                        defer arena.allocator().free(link_url);
                        try links_html.writer().print(fmt_link, .{ link_url, media_type, title, link_url });
                    }
                    try links_html.appendSlice("</ul>");
                    session.data.links_body = links_html.toOwnedSlice();
                    try printFormWithLinks(res, session.data.links_body, tags);
                    return;
                },
                .unknown => {
                    try w.print("<p>Failed to parse content. Don't handle mimetype {s}</p>", .{content_type_value});
                    try w.print(form_fmt, .{ url, tags });
                    ctx.sessions.remove(session_index.?);
                    return;
                },
                else => {},
            }

            const body = resp.body_fifo.readableSlice(0);
            const feed = try f.Feed.initParse(&arena, valid_url, body, content_type);
            const feed_update = try f.FeedUpdate.fromHeadersCurl(last_header);
            var tags_slice = ArrayList([]const u8).init(arena.allocator());
            var iter_tags = mem.split(u8, tags, ",");
            while (iter_tags.next()) |tag| {
                try tags_slice.append(tag);
            }
            _ = try ctx.storage.addNewFeed(feed, feed_update, tags_slice.items);

            try w.print("<p>Added new feed {s}</p>", .{valid_url});
            try w.print(form_fmt, .{ "", "" });

            ctx.sessions.remove(session_index.?);

            return;
        }

        if (is_submit_feed_links) {
            var links = try ArrayList([]const u8).initCapacity(arena.allocator(), 2);
            defer links.deinit();
            iter = mem.split(u8, session.data.form_body, "&");
            while (iter.next()) |kv| {
                var iter_kv = mem.split(u8, kv, "=");
                const key = iter_kv.next() orelse continue;
                const value = iter_kv.next() orelse continue;
                if (mem.eql(u8, "feed_link_checkbox", key)) {
                    try links.append(value);
                }
            }

            if (links.items.len == 0) {
                try w.writeAll("<p>Please choose atleast one link</p>");
                try printFormWithLinks(res, session.data.links_body, tags);
                return;
            }

            defer ctx.sessions.remove(session_index.?);

            for (links.items) |link| {
                const resp = try http.resolveRequestCurl(&arena, link, .{});

                const last_header = curl.getLastHeader(resp.headers_fifo.readableSlice(0));
                const content_type_value = curl.getHeaderValue(last_header, "content-type:") orelse {
                    try w.writeAll("<p>No Content-Type HTTP header</p>");
                    try w.print(form_fmt, .{ url, tags });
                    return;
                };
                const content_type = http.ContentType.fromString(content_type_value);
                switch (content_type) {
                    .html, .unknown => {
                        try w.print(
                            "<p>Failed to add url {s}. Don't handle mimetype {s}</p>",
                            .{ link, content_type_value },
                        );
                    },
                    else => {},
                }

                const body = resp.body_fifo.readableSlice(0);
                const feed = try f.Feed.initParse(&arena, link, body, content_type);
                const feed_update = try f.FeedUpdate.fromHeadersCurl(last_header);
                var tags_slice = ArrayList([]const u8).init(arena.allocator());
                var iter_tags = mem.split(u8, tags, ",");
                while (iter_tags.next()) |tag| {
                    try tags_slice.append(tag);
                }
                _ = try ctx.storage.addNewFeed(feed, feed_update, tags_slice.items);
                try w.print("<p>Added feed {s}</p>", .{link});
            }
            try w.print(form_fmt, .{ "", "" });
            return;
        }
    }

    fn feedAddPost(ctx: *Context, res: *web.Response, req: web.Request, _: ?*const anyopaque) !void {
        ctx.sessions.cleanOld();
        var session_index: usize = 0;
        var session = blk: {
            const token = try getCookieToken(req);
            const index_opt = if (token) |t| ctx.sessions.getIndex(t) else null;
            if (index_opt) |index| {
                session_index = index;
                const session = &ctx.sessions.list.items[index];
                session.arena.allocator().free(session.data.form_body);
                break :blk session;
            }
            var arena = std.heap.ArenaAllocator.init(ctx.allocator);
            break :blk try ctx.sessions.new(arena);
        };
        errdefer ctx.sessions.remove(session_index);
        var arena = session.arena;
        session.data.form_body = (try zuri.Uri.decode(arena.allocator(), req.body())) orelse (try Allocator.dupe(arena.allocator(), u8, req.body()));

        const token_fmt = "token={d}; path=/feed/add";
        const u64_max_char = 20;
        var buf: [token_fmt.len + u64_max_char]u8 = undefined;
        try res.headers.put("Set-Cookie", try fmt.bufPrint(&buf, token_fmt, .{session.id}));
        res.status_code = .found;
        try res.headers.put("Location", "/feed/add");
    }

    fn getCookieToken(req: web.Request) !?u64 {
        var it = req.iterator();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase("cookie", header.key)) {
                const end = mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
                var iter = mem.split(u8, header.value[0..end], "=");
                if (iter.next()) |key| {
                    if (mem.eql(u8, "token", mem.trim(u8, key, " "))) {
                        const value = iter.next() orelse continue;
                        return try fmt.parseUnsigned(u64, value, 10);
                    }
                }
            }
        }
        return null;
    }

    const form_start = "<form action=\"/feed/add\" method=\"POST\">";
    const form_end = "</form>";
    const input_url_hidden = "<input type=\"hidden\" name=\"feed_url\" id=\"feed_url\" value=\"{s}\">";
    const input_url =
        \\<div>
        \\<label for="feed_url">Feed/Site url</label>
        \\<input type="text" name="feed_url" id="feed_url" placeholder="Enter site or feed url" value="{s}">
        \\</div>
    ;
    const input_tags =
        \\<div>
        \\<label for="tags">Tags</label>
        \\<input type="text" id="tags" name="tags" value="{s}">
        \\</div>
    ;

    const button_fmt = "<button type=\"submit\" name=\"{s}\">Add feed{s}</button>";
    const form_fmt = form_start ++ input_url ++ input_tags ++ fmt.comptimePrint(button_fmt, .{ "submit_feed", "" }) ++ form_end;

    fn printFormWithLinks(res: *web.Response, links_body: []const u8, tags: []const u8) !void {
        const w = res.writer();
        try w.writeAll(form_start);
        try w.print(input_tags, .{tags});
        try w.writeAll(links_body);
        try w.print(button_fmt, .{ "submit_feed_links", "(s)" });
        try w.writeAll(form_end);
    }

    fn tagGet(ctx: *Context, res: *web.Response, req: web.Request, captures: ?*const anyopaque) !void {
        _ = ctx;
        _ = req;
        const w = res.writer();
        try res.headers.put("Content-Type", "text/html");
        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();

        try w.writeAll("<a href=\"/\">Home</a>");

        var all_tags = try ctx.storage.getAllTags();
        if (all_tags.len == 0) {
            try w.writeAll("<p>There are no tags</p>");
            return;
        }

        var active_tags = try ArrayList([]const u8).initCapacity(arena.allocator(), 3);
        defer active_tags.deinit();
        const tags_raw = @ptrCast(
            *const []const u8,
            @alignCast(
                @alignOf(*const []const u8),
                captures,
            ),
        );
        const tags = (try zuri.Uri.decode(arena.allocator(), tags_raw.*)) orelse tags_raw.*;
        var it = mem.split(u8, tags, "+");
        while (it.next()) |tag| {
            if (hasTag(all_tags, tag)) {
                try active_tags.append(tag);
            }
        }

        if (active_tags.items.len == 0) {
            var it_tags = mem.split(u8, tags, "+");
            try w.writeAll("<p>Could not find tags: ");
            while (it_tags.next()) |tag| {
                try w.writeAll(tag);
                if (it_tags.rest().len > 0) {
                    try w.writeAll(", ");
                }
            }
            try w.writeAll("</p>");
            // TODO: print all tags
            return;
        }

        try w.writeAll("<p>Active tags:</p>");
        try w.writeAll("<ul>");

        if (active_tags.items.len == 1) {
            try w.print("<li><a href=\"/\">{s}</a></li>", .{active_tags.items[0]});
        } else {
            var fb_alloc = std.heap.stackFallback(1024, arena.allocator());
            for (active_tags.items) |a_tag| {
                var alloc = fb_alloc.get();
                const tags_slug = try tagsSlugRemove(fb_alloc.get(), a_tag, active_tags.items);
                defer alloc.free(tags_slug);
                try w.print("<li><a href=\"/tag/{s}\">{s}</a></li>", .{ tags_slug, a_tag });
            }
        }
        try w.writeAll("</ul>");

        var recent_feeds = try ctx.storage.getRecentlyUpdatedFeedsByTags(active_tags.items);
        try w.writeAll("<p>Feeds</p>");
        try printFeeds(ctx.storage, res, recent_feeds);

        try w.writeAll("<p>All Tags</p>");
        try printTags(arena.allocator(), res, all_tags, active_tags.items);
    }

    fn hasTag(all_tags: []Storage.TagCount, tag: []const u8) bool {
        for (all_tags) |all_tag| {
            if (mem.eql(u8, tag, all_tag.name)) return true;
        }
        return false;
    }

    fn printElapsedTime(res: *web.Response, dt: Datetime, now: Datetime) !void {
        const delta = now.sub(dt);
        const w = res.writer();
        if (delta.days > 0) {
            const months = @divFloor(delta.days, 30);
            const years = @divFloor(delta.days, 365);
            if (years > 0) {
                try w.print("{d}Y", .{years});
            } else if (months > 0) {
                try w.print("{d}M", .{months});
            } else {
                try w.print("{d}d", .{delta.days});
            }
        } else if (delta.seconds > 0) {
            const minutes = @divFloor(delta.seconds, 60);
            const hours = @divFloor(minutes, 60);
            if (hours > 0) {
                try w.print("{d}h", .{hours});
            } else if (delta.days > 0) {
                try w.print("{d}m", .{minutes});
            }
        }
    }

    fn printFeeds(storage: *Storage, res: *web.Response, recent_feeds: []Storage.RecentFeed) !void {
        const now = Datetime.now();
        const w = res.writer();
        try w.writeAll("<ul>");
        for (recent_feeds) |feed| {
            try w.writeAll("<li>");
            if (feed.link) |link| {
                try w.print("<a href=\"{s}\">{s}</a>", .{ link, feed.title });
            } else {
                try w.print("{s}", .{feed.title});
            }
            if (feed.updated_timestamp) |timestamp| {
                try w.writeAll(" | ");
                const dt = Datetime.fromSeconds(@intToFloat(f64, timestamp));
                var buf: [32]u8 = undefined;
                const timestamp_str = fmt.bufPrint(&buf, timestamp_fmt, .{
                    dt.date.year, dt.date.month,  dt.date.day,
                    dt.time.hour, dt.time.minute, dt.time.second,
                });
                try w.print("<span title=\"{s}\">", .{timestamp_str});
                try printElapsedTime(res, dt, now);
                try w.writeAll("</span>");
            }

            // Get feed items
            const items = try storage.getItems(feed.id);
            try w.writeAll("<ul>");
            for (items) |item| {
                try w.writeAll("<li>");
                if (item.link) |link| {
                    try w.print("<a href=\"{s}\">{s}</a>", .{ link, item.title });
                } else {
                    try w.print("{s}", .{feed.title});
                }
                if (item.pub_date_utc) |timestamp| {
                    try w.writeAll(" | ");
                    const dt = Datetime.fromSeconds(@intToFloat(f64, timestamp));
                    var buf: [32]u8 = undefined;
                    const timestamp_str = fmt.bufPrint(&buf, timestamp_fmt, .{
                        dt.date.year, dt.date.month,  dt.date.day,
                        dt.time.hour, dt.time.minute, dt.time.second,
                    });
                    try w.print("<span title=\"{s}\">", .{timestamp_str});
                    try printElapsedTime(res, dt, now);
                    try w.writeAll("</span>");
                }
                try w.writeAll("</li>");
            }
            try w.writeAll("</ul>");

            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");
    }

    // Index displays most recenlty update feeds
    fn indexGet(ctx: *Context, res: *web.Response, req: web.Request, captures: ?*const anyopaque) !void {
        _ = req;
        _ = captures;
        try res.headers.put("Content-Type", "text/html");
        const w = res.writer();
        try w.writeAll("<a href=\"/feed/add\">Add new feed</a>");
        // Get most recently update feeds
        var recent_feeds = try ctx.storage.getRecentlyUpdatedFeeds();
        try w.writeAll("<p>Feeds</p>");
        try printFeeds(ctx.storage, res, recent_feeds);

        // Get tags with count
        var tags = try ctx.storage.getAllTags();
        try w.writeAll("<p>All Tags</p>");
        try printTags(ctx.allocator, res, tags, &[_][]const u8{});
    }

    fn printTags(allocator: Allocator, res: *web.Response, tags: []Storage.TagCount, active_tags: [][]const u8) !void {
        const w = res.writer();
        var fb_alloc = std.heap.stackFallback(1024, allocator);
        try w.writeAll("<ul>");
        for (tags) |tag| {
            try printTag(fb_alloc.get(), res, tag, active_tags);
        }
        try w.writeAll("</ul>");
    }

    fn printTag(allocator: Allocator, res: *web.Response, tag: Storage.TagCount, active_tags: [][]const u8) !void {
        const w = res.writer();
        var is_active = false;
        for (active_tags) |a_tag| {
            if (mem.eql(u8, tag.name, a_tag)) {
                is_active = true;
                break;
            }
        }
        if (!is_active) {
            // active_tags.len adds all the pluses (+)
            var total = active_tags.len + tag.name.len;
            for (active_tags) |t| total += t.len;
            var arr_slug = try ArrayList(u8).initCapacity(allocator, total);
            defer arr_slug.deinit();
            for (active_tags) |a_tag| {
                arr_slug.appendSliceAssumeCapacity(a_tag);
                arr_slug.appendAssumeCapacity('+');
            }
            arr_slug.appendSliceAssumeCapacity(tag.name);

            try w.print(
                \\<li>
                \\<a href="/tag/{s}">{s} - {d}</a>
                \\<a href="/tag/{s}">Add</a>
                \\</li>
            , .{ tag.name, tag.name, tag.count, arr_slug.items });
        } else {
            const tags_slug = try tagsSlugRemove(allocator, tag.name, active_tags);
            defer allocator.free(tags_slug);

            try w.print(
                \\<li>
                \\<a href="/tag/{s}">{s} - {d} [active]</a>
                \\<a href="{s}">Remove</a>
                \\</li>
            , .{ tag.name, tag.name, tag.count, tags_slug });
        }
    }

    // caller owns the memory
    fn tagsSlugRemove(allocator: Allocator, cmp_tag: []const u8, active_tags: [][]const u8) ![]const u8 {
        var arr_tags = try ArrayList(u8).initCapacity(allocator, 2);
        defer arr_tags.deinit();
        var has_first = false;
        for (active_tags) |path_tag| {
            if (mem.eql(u8, cmp_tag, path_tag)) continue;
            if (has_first) {
                try arr_tags.append('+');
            }
            has_first = true;
            try arr_tags.appendSlice(path_tag);
        }
        return arr_tags.toOwnedSlice();
    }
};

const global = struct {
    const ip = "127.0.0.1";
    const port = 8282;
    const url = fmt.comptimePrint("http://{s}:{d}", .{ ip, port });
};

fn expectContains(haystack: []const u8, needles: [][]const u8) !void {
    for (needles) |needle| {
        if (mem.indexOf(u8, haystack, needle) == null) {
            print("\n====== expected to find: =========\n", .{});
            print("{s}", .{needle});
            print("\n========= in string: ==============\n", .{});
            print("{s}", .{haystack});
            print("\n======================================\n", .{});
        }
    }
}

// cmd: just test-server
pub fn isTestServerRunning() !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var resp = try http.resolveRequestCurl(&arena, "http://localhost:8080", .{ .follow = true });
    defer resp.deinit();
    return @as(isize, 200) == resp.status_code;
}

pub fn expectTagPage(arena: *ArenaAllocator, tags: [][]const u8, expected_values: [][]const u8) !void {
    const url_tags = try mem.join(arena.allocator(), "%2B", tags);
    const path = try fmt.allocPrint(arena.allocator(), "{s}/tag/{s}", .{ global.url, url_tags });
    var resp = try http.resolveRequestCurl(arena, path, .{ .follow = false });
    try expectEqual(@as(isize, 200), resp.status_code);
    const resp_body = resp.body_fifo.readableSlice(0);

    try expectContains(resp_body, expected_values);
}

// TODO: Reason why on failing test I don't get error trace
test "@active post, get" {
    std.testing.log_level = .debug;
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    const new_len = http.general_request_headers_curl.len + 1;
    var new_headers: [new_len][]const u8 = undefined;
    for (http.general_request_headers_curl) |header, i| new_headers[i] = header;

    try curl.globalInit();
    defer curl.globalCleanup();

    try expect(try isTestServerRunning());

    // TODO: also test db/storage?
    var storage = try Storage.init(arena.allocator(), null);
    var sessions = Sessions.init(arena.allocator());
    defer sessions.deinit();
    // https://github.com/Luukdegram/apple_pie/blob/fb695aa9bc4d4a7bcabdd76c420e6b2ce118b2b7/src/server.zig#L210
    var server = try Server.init(arena.allocator(), &storage, &sessions);
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    defer {
        server.shutdown();
        thread.join();
    }

    const url = global.url;
    {
        // Index page: check if server is up
        var resp = try http.resolveRequestCurl(&arena, url ++ "/", .{ .follow = true });
        defer resp.deinit();
        try expectEqual(@as(isize, 200), resp.status_code);
    }

    {
        // Tags page: no tags
        var values = [_][]const u8{"<p>There are no tags</p>"};
        var tags = [_][]const u8{};
        try expectTagPage(&arena, &tags, &values);
    }

    {
        var resp = try http.resolveRequestCurl(&arena, url ++ "/feed/add", .{ .follow = false });
        try expectEqual(@as(isize, 200), resp.status_code);
        const resp_body = resp.body_fifo.readableSlice(0);
        var values = [_][]const u8{ "name=\"feed_url\"", "name=\"tags\"", "name=\"submit_feed\"" };
        try expectContains(resp_body, &values);
    }

    {
        // Try to add feed. Links return multiple links.
        const payload = "feed_url=localhost%3A8080%2Fmany-links.html&tags=tag1%2C+tag2%2C+tag3&submit_feed=";
        var opts = .{ .follow = false, .post_data = try arena.allocator().dupe(u8, payload) };
        var resp = try http.resolveRequestCurl(&arena, url ++ "/feed/add", opts);
        defer resp.deinit();
        try expectEqual(sessions.list.items.len, 1);

        const cookie_value = curl.getHeaderValue(resp.headers_fifo.readableSlice(0), "set-cookie:");
        try expect(cookie_value != null);
        new_headers[new_len - 1] = try fmt.allocPrint(arena.allocator(), "Cookie: {s}", .{cookie_value.?});

        var resp1 = try http.resolveRequestCurl(&arena, url ++ "/feed/add", .{ .follow = false, .headers = &new_headers });
        defer resp1.deinit();
        try expectEqual(@as(isize, 200), resp1.status_code);
        const resp_body = resp1.body_fifo.readableSlice(0);
        var values = [_][]const u8{
            "value=\"http://localhost:8080/rss2.rss\"",
            "name=\"feed_link_checkbox\"",
            "name=\"submit_feed_links\"",
        };
        try expectContains(resp_body, &values);
    }

    {
        // No links chosen
        const payload = "tags=tag1%2C+tag2%2C+tag3&feed_url=http%3A%2F%2Flocalhost%3A8080%2Fmany-links.html&feed_link_checkbox&submit_feed_links=";
        var opts = .{ .follow = false, .post_data = try arena.allocator().dupe(u8, payload), .headers = &new_headers };
        var resp = try http.resolveRequestCurl(&arena, url ++ "/feed/add", opts);
        defer resp.deinit();

        var resp1 = try http.resolveRequestCurl(&arena, url ++ "/feed/add", .{ .follow = false, .headers = &new_headers });
        defer resp1.deinit();
        try expectEqual(@as(isize, 200), resp1.status_code);
        const resp_body = resp1.body_fifo.readableSlice(0);
        var values = [_][]const u8{
            "Please choose atleast one link",
            "value=\"http://localhost:8080/rss2.rss\"",
            "name=\"feed_link_checkbox\"",
            "name=\"submit_feed_links\"",
        };
        try expectContains(resp_body, &values);
    }

    {
        // Choose two links
        const payload = "tags=tag1%2C+tag2%2C+tag3&feed_url=http%3A%2F%2Flocalhost%3A8080%2Fmany-links.html&feed_link_checkbox=http%3A%2F%2Flocalhost%3A8080%2Frss2.rss&feed_link_checkbox=http%3A%2F%2Flocalhost%3A8080%2Frss2.rss&submit_feed_links=";
        var opts = .{ .follow = false, .post_data = try arena.allocator().dupe(u8, payload), .headers = &new_headers };
        var resp = try http.resolveRequestCurl(&arena, url ++ "/feed/add", opts);
        defer resp.deinit();

        var resp1 = try http.resolveRequestCurl(&arena, url ++ "/feed/add", .{ .follow = false, .headers = &new_headers });
        defer resp1.deinit();
        try expectEqual(@as(isize, 200), resp1.status_code);
        const resp_body = resp1.body_fifo.readableSlice(0);
        var values = [_][]const u8{ "Added feed http://localhost:8080/rss2.rss", "name=\"submit_feed\"" };
        try expectContains(resp_body, &values);
        try expectEqual(sessions.list.items.len, 0);
    }

    {
        // Tags page: tags don't exist
        var tags = [_][]const u8{ "missing_tag", "no_tag" };
        var values = [_][]const u8{"<p>Could not find tags: missing_tag, no_tag</p>"};
        try expectTagPage(&arena, &tags, &values);
    }

    {
        // Tags page: check for valid tags
        var values = [_][]const u8{
            "href=\"/tag/tag2\"",
            "href=\"http://liftoff.msfc.nasa.gov/\"",
            "[active]",
            "href=\"/tag/tag1+tag2+tag3\"",
        };
        var tags = [_][]const u8{ "tag1", "tag2", "hello" };
        try expectTagPage(&arena, &tags, &values);
    }

    print("\nServer tests done\n", .{});
}
