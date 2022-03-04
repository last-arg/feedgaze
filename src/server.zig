const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const StringHashMap = std.hash_map.StringHashMap;
const fmt = std.fmt;
const builtin = @import("builtin");
const routez = @import("routez");
const RoutezServer = routez.Server;
const Request = routez.Request;
const Response = routez.Response;
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
const zfetch = @import("zfetch");
const log = std.log;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

// Resources
// POST-REDIRECT-GET | https://andrewlock.net/post-redirect-get-using-tempdata-in-asp-net-core/
// Generating session ids | https://codeahoy.com/2016/04/13/generating-session-ids/
// https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html#references

// pub const io_mode = .evented;

const timestamp_fmt = "{d}.{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC";

const SessionData = struct {
    form_body: []const u8 = "",
};

const Session = struct {
    id: u64,
    arena: std.heap.ArenaAllocator,
    data: SessionData,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
};

const Sessions = struct {
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
        const current = std.time.timestamp();
        const first = self.timestamps.items[0];
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

const Server = struct {
    const g = struct {
        var storage: *Storage = undefined;
        var sessions: *Sessions = undefined;
        var allocator: Allocator = undefined;
    };
    const Self = @This();
    server: RoutezServer,

    pub fn init(allocator: Allocator, storage: *Storage, sessions: *Sessions) Self {
        g.storage = storage;
        g.sessions = sessions;
        g.allocator = allocator;
        var server = RoutezServer.init(
            allocator,
            .{},
            .{
                routez.all("/", indexHandler),
                routez.all("/tag/{tags}", tagHandler),
                routez.all("/feed/add", feedAddHandler),
            },
        );
        // Don't get errors about address in use
        if (builtin.mode == .Debug) server.server.reuse_address = true;

        return Server{
            .server = server,
        };
    }

    fn feedAddHandler(req: Request, res: Response) !void {
        if (mem.eql(u8, req.method, "POST")) {
            try feedAddPost(req, res);
        } else if (mem.eql(u8, req.method, "GET")) {
            try feedAddGet(req, res);
        } else {
            // TODO: response https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/405
        }
    }

    fn getCookieToken(req: Request, allocator: Allocator) !?u64 {
        const headers_opt = try req.headers.get(allocator, "cookie");
        print("get cookie\n", .{});
        defer if (headers_opt) |headers| allocator.free(headers);
        if (headers_opt) |headers| {
            for (headers) |header| {
                const end = mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
                var iter = mem.split(u8, header.value[0..end], "=");
                if (iter.next()) |key| {
                    if (mem.eql(u8, "token", key)) {
                        const value = iter.next() orelse continue;
                        return try fmt.parseUnsigned(u64, value, 10);
                    }
                }
            }
        }
        return null;
    }

    const form_start = "<form action='/feed/add' method='POST'>";
    const form_end = "</form>";
    const input_url_hidden = "<input type='hidden' name='feed_url' id='feed_url' value='{s}'>";
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

    const button_fmt = "<button type='submit' name='{s}'>Add feed{s}</button>";
    const form_fmt = form_start ++ input_url ++ input_tags ++ fmt.comptimePrint(button_fmt, .{ "submit_feed", "" }) ++ form_end;

    fn feedAddGet(req: Request, res: Response) !void {
        print("add GET\n", .{});
        var arena = std.heap.ArenaAllocator.init(g.allocator);
        defer arena.deinit();

        const token: ?u64 = try getCookieToken(req, g.allocator);
        const session_index: ?usize = if (token) |t| g.sessions.getIndex(t) else null;

        try res.write("<p>Home</p>");
        if (session_index == null) {
            try res.print(form_fmt, .{ "localhost:8080/many-links.html", "tag1, tag2, tag3" });
            return;
        }
        var session = g.sessions.list.items[session_index.?];
        if (session.data.form_body.len == 0) {
            try res.write("<p>There is no form data to handle</p>");
            try res.print(form_fmt, .{ "", "" });
            g.sessions.remove(session_index.?);
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
                tags = value;
            } else if (mem.eql(u8, "submit_feed", key)) {
                is_submit_feed = true;
            } else if (mem.eql(u8, "submit_feed_links", key)) {
                is_submit_feed_links = true;
            }
        }

        if (!is_submit_feed and !is_submit_feed_links) {
            try res.write("<p>Submitted form data is invalid. Can't determine what type of form was submitted.</p>");
            try res.print(form_fmt, .{ url, tags });
            g.sessions.remove(session_index.?);
            return;
        }

        if (is_submit_feed) {
            print("Submit feed\n{s}\n", .{session.data.form_body});
            if (url.len == 0) {
                try res.write("<p>No url entered</p>");
                try res.print(form_fmt, .{ "", tags });
                g.sessions.remove(session_index.?);
                return;
            }
            const valid_url = url_util.makeValidUrl(arena.allocator(), url) catch {
                try res.write("<p>Invalid url entered</p>");
                try res.print(form_fmt, .{ url, tags });
                g.sessions.remove(session_index.?);
                return;
            };

            var url_req = try http.resolveRequest2(&arena, valid_url, &http.general_request_headers);
            const content_type_value = http.getContentType(url_req.headers.list.items) orelse {
                try res.write("<p>Failed to find Content-Type</p>");
                try res.print(form_fmt, .{ url, tags });
                g.sessions.remove(session_index.?);
                return;
            };
            const content_type = http.ContentType.fromString(content_type_value);
            switch (content_type) {
                .html => {
                    // TODO: save to session? If submitting fails
                    const body = try http.getRequestBody(&arena, url_req);
                    const html_links = try parse.Html.parseLinks(arena.allocator(), body);
                    try printFormLinks(&arena, res, html_links, valid_url, tags);
                    return;
                },
                .unknown => {
                    try res.print("<p>Failed to parse content. Don't handle mimetype {s}</p>", .{content_type_value});
                    try res.print(form_fmt, .{ url, tags });
                    g.sessions.remove(session_index.?);
                    return;
                },
                else => {},
            }

            const body = try http.getRequestBody(&arena, url_req);
            const feed = try f.Feed.initParse(&arena, valid_url, body, content_type);
            const feed_update = try f.FeedUpdate.fromHeaders(url_req.headers.list.items);
            _ = try g.storage.addNewFeed(feed, feed_update, tags);

            try res.print("<p>Added new feed {s}</p>", .{valid_url});
            try res.print(form_fmt, .{ "", "" });

            g.sessions.remove(session_index.?);

            return;
        }

        if (is_submit_feed_links) {
            @panic("TODO: submit links");
        }
    }

    fn feedAddPost(req: Request, res: Response) !void {
        g.sessions.cleanOld();
        var session = blk: {
            const token = try getCookieToken(req, g.allocator);
            const index_opt = if (token) |t| g.sessions.getIndex(t) else null;
            if (index_opt) |index| {
                // TODO: clean/deinit current session data?
                break :blk &g.sessions.list.items[index];
            }
            var arena = std.heap.ArenaAllocator.init(g.allocator);
            break :blk try g.sessions.new(arena);
        };
        errdefer {
            g.sessions.remove(session.id);
            session.deinit();
        }
        var arena = session.arena;
        var body_decoded = (try zuri.Uri.decode(arena.allocator(), req.body)) orelse req.body;
        // NOTE: might replace pluses ('+') that are not spaces
        mem.replaceScalar(u8, @ptrCast(*[]u8, &body_decoded).*, '+', ' ');
        session.data = .{ .form_body = body_decoded };

        const token_fmt = "token={d}; path=/feed/add";
        const u64_max_char = 20;
        var buf: [token_fmt.len + u64_max_char]u8 = undefined;
        try res.headers.put("Set-Cookie", try fmt.bufPrint(&buf, token_fmt, .{session.id}));
        res.status_code = .Found;
        try res.headers.put("Location", "/feed/add");
    }

    fn printFormLinks(arena: *ArenaAllocator, res: Response, html_page: parse.Html.Page, valid_url: []const u8, tags: []const u8) !void {
        try res.write(form_start);
        try res.print(input_tags, .{tags});
        const base_uri = try zuri.Uri.parse(valid_url, true);
        const fallback_title = html_page.title orelse "<no-title>";
        try res.write("<p>Pick a feed link(s) to add</p>");
        try res.write("<ul>");
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
            try res.print(fmt_link, .{ link_url, media_type, title, link_url });
        }
        try res.write("</ul>");
        try res.print(button_fmt, .{ "submit_feed_links", "(s)" });
        try res.write(form_end);
    }

    pub fn submitFeed(arena: *ArenaAllocator, url_input: []const u8) !SessionData {
        if (url_input.len == 0) {
            return SessionData{ .ty = .fail_no_url };
        }
        const url = url_util.makeValidUrl(arena.allocator(), url_input) catch {
            return SessionData{ .ty = .fail_invalid_url };
        };

        var req = try http.resolveRequest2(arena, url, &http.general_request_headers);
        return SessionData{ .ty = .resolve, .req = req };
    }

    pub fn submitFeedLinks(
        arena: *ArenaAllocator,
        session: *Session,
        try_urls: [][]const u8,
        initial_url: ?[]const u8,
        tags_input: []const u8,
    ) !void {
        _ = arena;
        _ = try_urls;
        _ = session;
        _ = initial_url;
        _ = tags_input;
    }

    fn addFeed(feed: parse.Feed, tags: []const u8) !u64 {
        return try g.storage.addNewFeed(feed, tags);
    }

    fn tagHandler(req: Request, res: Response, args: *const struct { tags: []const u8 }) !void {
        _ = req;
        var arena = std.heap.ArenaAllocator.init(g.allocator);
        defer arena.deinit();
        var all_tags = try g.storage.getAllTags();

        var active_tags = try ArrayList([]const u8).initCapacity(arena.allocator(), 3);
        defer active_tags.deinit();

        // application/x-www-form-urlencoded encodes spaces as pluses (+)
        var it = mem.split(u8, args.tags, "+");
        while (it.next()) |tag| {
            if (hasTag(all_tags, tag)) {
                try active_tags.append(tag);
                continue;
            }
        }

        try res.write("<a href='/'>Home</a>");

        try res.write("<p>Active tags:</p> ");

        try res.write("<ul>");
        if (active_tags.items.len == 1) {
            try res.print("<li><a href='/'>{s}</a></li>", .{active_tags.items[0]});
        } else {
            var fb_alloc = std.heap.stackFallback(1024, arena.allocator());
            for (active_tags.items) |a_tag| {
                var alloc = fb_alloc.get();
                const tags_slug = try tagsSlugRemove(fb_alloc.get(), a_tag, active_tags.items);
                defer alloc.free(tags_slug);
                try res.print("<li><a href='/tag/{s}'>{s}</a></li>", .{ tags_slug, a_tag });
            }
        }
        try res.write("</ul>");

        var recent_feeds = try g.storage.getRecentlyUpdatedFeedsByTags(active_tags.items);
        try res.write("<p>Feeds</p>");
        try printFeeds(res, recent_feeds);

        try res.write("<p>All Tags</p>");
        try printTags(arena.allocator(), res, all_tags, active_tags.items);
    }

    fn hasTag(all_tags: []Storage.TagCount, tag: []const u8) bool {
        for (all_tags) |all_tag| {
            if (mem.eql(u8, tag, all_tag.name)) return true;
        }
        return false;
    }

    fn printElapsedTime(res: Response, dt: Datetime, now: Datetime) !void {
        const delta = now.sub(dt);
        if (delta.days > 0) {
            const months = @divFloor(delta.days, 30);
            const years = @divFloor(delta.days, 365);
            if (years > 0) {
                try res.print("{d}Y", .{years});
            } else if (months > 0) {
                try res.print("{d}M", .{months});
            } else {
                try res.print("{d}d", .{delta.days});
            }
        } else if (delta.seconds > 0) {
            const minutes = @divFloor(delta.seconds, 60);
            const hours = @divFloor(minutes, 60);
            if (hours > 0) {
                try res.print("{d}h", .{hours});
            } else if (delta.days > 0) {
                try res.print("{d}m", .{minutes});
            }
        }
    }

    fn printFeeds(res: Response, recent_feeds: []Storage.RecentFeed) !void {
        const now = Datetime.now();
        try res.write("<ul>");
        for (recent_feeds) |feed| {
            try res.write("<li>");
            if (feed.link) |link| {
                try res.print("<a href=\"{s}\">{s}</a>", .{ link, feed.title });
            } else {
                try res.print("{s}", .{feed.title});
            }
            if (feed.updated_timestamp) |timestamp| {
                try res.write(" | ");
                const dt = Datetime.fromSeconds(@intToFloat(f64, timestamp));
                var buf: [32]u8 = undefined;
                const timestamp_str = fmt.bufPrint(&buf, timestamp_fmt, .{
                    dt.date.year, dt.date.month,  dt.date.day,
                    dt.time.hour, dt.time.minute, dt.time.second,
                });
                try res.print("<span title='{s}'>", .{timestamp_str});
                try printElapsedTime(res, dt, now);
                try res.write("</span>");
            }

            // Get feed items
            const items = try g.storage.getItems(feed.id);
            try res.write("<ul>");
            for (items) |item| {
                try res.write("<li>");
                if (item.link) |link| {
                    try res.print("<a href=\"{s}\">{s}</a>", .{ link, item.title });
                } else {
                    try res.print("{s}", .{feed.title});
                }
                if (item.pub_date_utc) |timestamp| {
                    try res.write(" | ");
                    const dt = Datetime.fromSeconds(@intToFloat(f64, timestamp));
                    var buf: [32]u8 = undefined;
                    const timestamp_str = fmt.bufPrint(&buf, timestamp_fmt, .{
                        dt.date.year, dt.date.month,  dt.date.day,
                        dt.time.hour, dt.time.minute, dt.time.second,
                    });
                    try res.print("<span title='{s}'>", .{timestamp_str});
                    try printElapsedTime(res, dt, now);
                    try res.write("</span>");
                }
                try res.write("</li>");
            }
            try res.write("</ul>");

            try res.write("</li>");
        }
        try res.write("</ul>");
    }

    // Index displays most recenlty update feeds
    fn indexHandler(req: Request, res: Response) !void {
        _ = req;
        try res.write("<a href='/feed/add'>Add new feed</a>");
        // Get most recently update feeds
        var recent_feeds = try g.storage.getRecentlyUpdatedFeeds();
        try res.write("<p>Feeds</p>");
        try printFeeds(res, recent_feeds);

        // Get tags with count
        var tags = try g.storage.getAllTags();
        try res.write("<p>All Tags</p>");
        try printTags(g.allocator, res, tags, &[_][]const u8{});
    }

    fn printTags(allocator: Allocator, res: Response, tags: []Storage.TagCount, active_tags: [][]const u8) !void {
        var fb_alloc = std.heap.stackFallback(1024, allocator);
        try res.write("<ul>");
        for (tags) |tag| {
            try printTag(fb_alloc.get(), res, tag, active_tags);
        }
        try res.write("</ul>");
    }

    fn printTag(allocator: Allocator, res: Response, tag: Storage.TagCount, active_tags: [][]const u8) !void {
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

            try res.print(
                \\<li>
                \\<a href='/tag/{s}'>{s} - {d}</a>
                \\<a href='/tag/{s}'>Add</a>
                \\</li>
            , .{ tag.name, tag.name, tag.count, arr_slug.items });
        } else {
            const tags_slug = try tagsSlugRemove(allocator, tag.name, active_tags);
            defer allocator.free(tags_slug);

            try res.print(
                \\<li>
                \\<a href='/tag/{s}'>{s} - {d} [active]</a>
                \\<a href='{s}'>Remove</a>
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
};

pub fn run(storage: *Storage) !void {
    print("run server\n", .{});
    var gen_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    var sessions = Sessions.init(gen_alloc.allocator());
    defer sessions.deinit();
    var server = Server.init(gen_alloc.allocator(), storage, &sessions);
    var addr = try Address.parseIp(global.ip, global.port);
    try server.server.listen(addr);
}

fn testServer(allocator: Allocator) !void {
    var storage = try Storage.init(allocator, null);
    try run(&storage);
}

test "@active" {
    const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    const thread = try std.Thread.spawn(.{}, testServer, .{arena.allocator()});
    defer thread.join();
    // Hack to make sure server is up before making request
    // TODO?: check for server address?
    std.time.sleep(1 * std.time.ns_per_ms);
    print("Server running\n", .{});

    const url = "http://localhost:8282/feed/add";
    var headers = zfetch.Headers.init(arena.allocator());
    defer headers.deinit();
    const body = "feed_url=localhost%3A8080%2Fmany-links.html&tags=tag1%2C+tag2%2C+tag3&submit_feed=";
    const req = try zfetch.Request.init(arena.allocator(), url, null);
    try req.do(.POST, headers, body);
    try expectEqual(@as(u16, 302), req.status.code);
    var cookie_value: []const u8 = "";
    for (req.headers.list.items) |h| {
        if (mem.eql(u8, "set-cookie", h.name)) cookie_value = h.value;
    }
    try expect(cookie_value.len > 0);
    req.socket.close();

    const req1 = try zfetch.Request.init(arena.allocator(), url, null);
    defer req1.deinit();
    try headers.appendValue("Cookie", cookie_value);
    try req1.do(.GET, headers, null);
    try expectEqual(@as(u16, 200), req1.status.code);
    const resp_body = try http.getRequestBody(&arena, req1);
    try expect(mem.indexOf(u8, resp_body, "submit_feed_links") != null);
    print("{s}\n", .{resp_body});

    // const body_links = tags=tag1%2C+tag2%2C+tag3&feed_link_checkbox=http%3A%2F%2Flocalhost%3A8080%2Frss2.rss&feed_link_checkbox=http%3A%2F%2Flocalhost%3A8080%2Fatom.atom&submit_feed_links=
}
