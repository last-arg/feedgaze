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
const zuri = @import("zuri");
const log = std.log;

// Resources
// POST-REDIRECT-GET | https://andrewlock.net/post-redirect-get-using-tempdata-in-asp-net-core/

// pub const io_mode = .evented;

// TODO: how to handle displaying untagged feeds?

const timestamp_fmt = "{d}.{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC";

const FormData = union(enum) {
    success: []u64, // ids
    html: struct {
        ty: enum { view, no_pick } = .view,
        url: []const u8,
        tags: []const u8,
        page: parse.Html.Page,
    },
    fail: struct {
        url: []const u8 = "",
        // tags?
        ty: enum { empty_url, invalid_url, invalid_form, unknown } = .unknown,
        msg: []const u8 = "Unknown problem occured. Try again.",
    },
};

const Session = struct {
    id: u64, // TODO: change to more secure
    // TODO: use union instead?
    data: StringHashMap([]const u8),
    html_page: ?parse.Html.Page = null,
    added_ids: []u64 = &[_]u64{},
    arena: std.heap.ArenaAllocator,
    form_data: FormData,

    pub fn deinit(self: *@This()) void {
        self.data.deinit();
        self.arena.deinit();
    }
};

const Sessions = struct {
    const Self = @This();
    allocator: Allocator,
    list: ArrayList(Session),

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .list = ArrayList(Session).init(allocator),
        };
    }

    pub fn new(self: *Self, arena: ArenaAllocator) !*Session {
        var result = try self.list.addOne();
        // var arena = std.heap.ArenaAllocator.init(self.allocator);
        result.* = Session{
            // TODO: generate token
            .id = self.list.items.len,
            // TODO: for some reason using arena.allocator() gives segmentation fault
            .data = StringHashMap([]const u8).init(self.allocator),
            .arena = arena,
            .form_data = .{ .fail = .{} },
        };
        return result;
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
    };
    const Self = @This();
    server: RoutezServer,

    pub fn init(storage: *Storage, sessions: *Sessions) Self {
        g.storage = storage;
        g.sessions = sessions;
        var server = RoutezServer.init(
            global_allocator,
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
        defer if (headers_opt) |headers| allocator.free(headers);
        if (headers_opt) |headers| {
            for (headers) |header| {
                var iter = mem.split(u8, header.value, "=");
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

    const button_submit = "<button type='submit' name='{s}'>Add feed{s}</button>";
    const form_start_same = form_start ++ input_url ++ input_tags;
    const form_base = form_start_same ++ fmt.comptimePrint(button_submit, .{ "submit_feed", "" }) ++ form_end;

    fn feedAddGet(req: Request, res: Response) !void {
        var arena = std.heap.ArenaAllocator.init(global_allocator);
        defer arena.deinit();

        const token: ?u64 = try getCookieToken(req, global_allocator);
        const session_index: ?usize = if (token) |t| g.sessions.getIndex(t) else null;
        print("COOKIE TOKEN: {}\n", .{token});

        if (session_index == null) {
            // TODO: empty string args when not debugging
            try res.print(form_base, .{ "localhost:8080/many-links.html", "tag1, tag2, tag3" });
            return;
        }

        var session = g.sessions.list.items[session_index.?];
        switch (session.form_data) {
            .success => |ids| {
                if (ids.len > 0) {
                    for (ids) |id| {
                        try res.print("Added id {d}", .{id});
                    }
                    // TODO: print added links
                    try res.print(form_base, .{ "", "" });
                }

                session.deinit();
                _ = g.sessions.list.swapRemove(session_index.?);
                if (token) |_| res.headers.put("Set-Cookie", "token=; path=/feed/add; Max-Age=0") catch {};
            },
            .html => |data| {
                switch (data.ty) {
                    .view => {
                        if (data.page.links.len > 0) {
                            try res.print("<p>{s} has several feeds</p>", .{data.url});
                            try printFormLinks(&arena, res, data.page.links, data.url, data.tags);
                        } else {
                            try res.print("<p>Found on feeds on {s}</p>", .{data.url});
                            try res.print(form_base, .{ data.url, data.tags });
                        }
                    },
                    .no_pick => {
                        try res.print("<p>{s} has several feeds</p>", .{data.url});
                        try res.write("<p>No feed(s) chosen. Please choose atleast one feed</p>");
                        try printFormLinks(&arena, res, data.page.links, data.url, data.tags);
                    },
                }
            },
            .fail => |data| {
                _ = data;
                try res.print("<p>Failed to add {s}</p>", .{data.url});
                try res.print("<p>{s}</p>", .{data.msg});

                session.deinit();
                _ = g.sessions.list.swapRemove(session_index.?);
                if (token) |_| res.headers.put("Set-Cookie", "token=; path=/feed/add; Max-Age=0") catch {};
            },
        }
    }

    fn printFormLinks(arena: *ArenaAllocator, res: Response, links: []parse.Html.Link, initial_url: []const u8, tags: []const u8) !void {
        try res.print(form_start ++ input_url_hidden ++ input_tags, .{ initial_url, tags });
        const base_uri = try zuri.Uri.parse(initial_url, true);
        try res.write("<ul>");
        for (links) |link| {
            const title = link.title orelse "";
            const url = try url_util.makeWholeUrl(arena.allocator(), base_uri, link.href);
            try res.print(
                \\<li>
                \\  <label>
                \\    <input type='checkbox' name='picked_feed' value='{s}'>
                \\    [{s}] {s}
                \\  </label>
                \\  <div>{s}</div>
                \\</li>
            , .{ url, link.media_type.toString(), title, url });
        }
        try res.write("</ul>");
        // TODO: button
        try res.write(fmt.comptimePrint(button_submit, .{ "submit_feed_links", "(s)" }) ++ form_end);
        try res.write(form_end);
    }

    fn feedAddPost(req: Request, res: Response) !void {
        var session = blk: {
            const token = try getCookieToken(req, global_allocator);
            const index_opt = if (token) |t| g.sessions.getIndex(t) else null;
            if (index_opt) |index| {
                break :blk &g.sessions.list.items[index];
            }
            var arena = std.heap.ArenaAllocator.init(global_allocator);
            break :blk try g.sessions.new(arena);
        };

        errdefer {
            session.deinit();
            _ = g.sessions.list.pop();
        }
        var session_arena = session.arena;

        // Get submitted form values
        var is_submit_feed = false;
        var is_submit_feed_links = false;
        var tags_input: []const u8 = "";
        var feed_url: []const u8 = "";
        var page_index: ?usize = null;
        var urls_list = try ArrayList([]const u8).initCapacity(session_arena.allocator(), 2);
        const body_decoded = (try zuri.Uri.decode(session_arena.allocator(), req.body)) orelse req.body;
        var iter = mem.split(u8, body_decoded, "&");
        while (iter.next()) |key_value| {
            var iter_key_value = mem.split(u8, key_value, "=");
            const key = iter_key_value.next() orelse continue;
            var value = iter_key_value.next() orelse continue;
            if (mem.eql(u8, "feed_url", key)) {
                feed_url = mem.trim(u8, value, "+");
            } else if (mem.eql(u8, "picked_feed", key)) {
                try urls_list.append(mem.trim(u8, value, "+"));
            } else if (mem.eql(u8, "tags", key)) {
                mem.replaceScalar(u8, @ptrCast(*[]u8, &value).*, '+', ' ');
                tags_input = value;
            } else if (mem.eql(u8, "submit_feed", key)) {
                is_submit_feed = true;
            } else if (mem.eql(u8, "submit_feed_links", key)) {
                is_submit_feed_links = true;
            } else if (mem.eql(u8, "page_index", key)) {
                page_index = try fmt.parseUnsigned(usize, value, 10);
            }
        }

        if (is_submit_feed) {
            try submitFeed(&session_arena, session, feed_url, tags_input);
        } else if (is_submit_feed_links) {
            try submitFeedLinks(&session_arena, session, urls_list.items, feed_url, tags_input);
        } else {
            try session.data.put("invalid_form", "");
        }

        try session.data.put("tags", tags_input);

        try res.headers.put("Set-Cookie", try fmt.allocPrint(session_arena.allocator(), "token={d}; path=/feed/add", .{session.id}));
        res.status_code = .Found;
        try res.headers.put("Location", "/feed/add");
    }

    pub fn submitFeed(arena: *ArenaAllocator, session: *Session, first_url: []const u8, tags_input: []const u8) !void {
        if (first_url.len == 0) {
            try session.data.put("missing_url", "");
            return;
        }

        const url = url_util.makeValidUrl(arena.allocator(), first_url) catch {
            try session.data.put("invalid_url", first_url);
            return;
        };

        var resp = try http.resolveRequest(arena, url, null, null);

        const resp_ok = switch (resp) {
            .ok => |ok| ok,
            .not_modified => {
                log.err("resolveRequest() fn returned .not_modified union value. This should not happen when adding new feed. Input url: {s}", .{url});
                // TODO: hook up on GET page
                // message: 'Failed to retrieve feed from <url>'
                try session.data.put("failed_url", url);
                return;
            },
            .fail => |msg| {
                // TODO: hook up on GET page
                // message: 'Failed to retrieve feed from <url>'
                try session.data.put("failed_url", url);
                try session.data.put("failed_msg", msg);
                return;
            },
        };

        const feed = switch (resp_ok.content_type) {
            .html => {
                const html_page = try parse.Html.parseLinks(global_allocator, resp_ok.body);
                // TODO: if (html_page.links.len == 1) make request to add feed
                session.form_data = .{ .html = .{ .url = url, .tags = tags_input, .page = html_page } };
                return;
            },
            .xml => try parse.parse(arena, resp_ok.body),
            .xml_atom => try parse.Atom.parse(arena, resp_ok.body),
            .xml_rss => try parse.Rss.parse(arena, resp_ok.body),
            .json, .json_feed => try parse.Json.parse(arena, resp_ok.body),
            .unknown => parse.parse(arena, resp_ok.body) catch try parse.Json.parse(arena, resp_ok.body),
        };
        var ids = try ArrayList(u64).initCapacity(arena.allocator(), 1);
        defer ids.deinit();
        ids.appendAssumeCapacity(try addFeed(feed, resp_ok.headers, url, tags_input));
        session.form_data = .{ .success = ids.toOwnedSlice() };
    }

    pub fn submitFeedLinks(
        arena: *ArenaAllocator,
        session: *Session,
        try_urls: [][]const u8,
        initial_url: ?[]const u8,
        tags_input: []const u8,
    ) !void {
        if (initial_url == null) {
            session.form_data = .{ .fail = .{ .ty = .empty_url, .msg = "Can't do anything with no url" } };
            return;
        } else if (try_urls.len == 0) {
            if (session.form_data == .html) {
                session.form_data.html.ty = .no_pick;
            } else {
                session.form_data = .{ .fail = .{ .url = initial_url.?, .msg = "Invalid session" } };
            }
            return;
        }

        var added_ids = try ArrayList(u64).initCapacity(arena.allocator(), try_urls.len);
        defer added_ids.deinit();
        for (try_urls) |try_url| {
            const url = try url_util.makeValidUrl(arena.allocator(), try_url);
            var resp = try http.resolveRequest(arena, url, null, null);

            const resp_ok = switch (resp) {
                .ok => |ok| ok,
                .not_modified => {
                    log.err("resolveRequest() fn returned .not_modified union value. This should not happen when adding new feed. Input url: {s}", .{url});
                    // TODO: send somekind or http error
                    continue;
                },
                .fail => |msg| {
                    log.err("Failed to resolve url {s}. Returned error message: {s}", .{ url, msg });
                    continue;
                },
            };
            const feed = switch (resp_ok.content_type) {
                .xml => try parse.parse(arena, resp_ok.body),
                .xml_atom => try parse.Atom.parse(arena, resp_ok.body),
                .xml_rss => try parse.Rss.parse(arena, resp_ok.body),
                .json, .json_feed => try parse.Json.parse(arena, resp_ok.body),
                .unknown => parse.parse(arena, resp_ok.body) catch try parse.Json.parse(arena, resp_ok.body),
                .html => {
                    log.warn("Skipping adding {s} because it returned html content", .{try_url});
                    continue;
                },
            };
            const feed_id = try addFeed(feed, resp_ok.headers, url, tags_input);
            added_ids.appendAssumeCapacity(feed_id);
        }
        session.form_data = .{ .success = added_ids.toOwnedSlice() };
    }

    fn addFeed(feed: parse.Feed, headers: http.RespHeaders, url: []const u8, tags: []const u8) !u64 {
        var savepoint = try g.storage.db.sql_db.savepoint("server_addFeed");
        defer savepoint.rollback();
        const query = "select id as feed_id, updated_timestamp from feed where location = ? limit 1;";
        var feed_id: u64 = 0;
        if (try g.storage.db.one(Storage.CurrentData, query, .{url})) |row| {
            try g.storage.updateUrlFeed(.{
                .current = row,
                .headers = headers,
                .feed = feed,
            }, .{ .force = true });
            try g.storage.addTags(row.feed_id, tags);
            feed_id = row.feed_id;
        } else {
            feed_id = try g.storage.addFeed(feed, url);
            try g.storage.addFeedUrl(feed_id, headers);
            try g.storage.addItems(feed_id, feed.items);
            try g.storage.addTags(feed_id, tags);
        }
        savepoint.commit();
        return feed_id;
    }

    fn tagHandler(req: Request, res: Response, args: *const struct { tags: []const u8 }) !void {
        _ = req;
        var arena = std.heap.ArenaAllocator.init(global_allocator);
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
        // Get most recently update feeds
        var recent_feeds = try g.storage.getRecentlyUpdatedFeeds();
        try res.write("<p>Feeds</p>");
        try printFeeds(res, recent_feeds);

        // Get tags with count
        var tags = try g.storage.getAllTags();
        try res.write("<p>All Tags</p>");
        try printTags(global_allocator, res, tags, &[_][]const u8{});
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
    var server = Server.init(storage, &sessions);
    var addr = try Address.parseIp(global.ip, global.port);
    try server.server.listen(addr);
}
