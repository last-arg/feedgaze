const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const builtin = @import("builtin");
const routez = @import("routez");
const RoutezServer = routez.Server;
const Request = routez.Request;
const Response = routez.Response;
const print = std.debug.print;
const allocator = std.heap.page_allocator;
const Address = std.net.Address;
const Storage = @import("feed_db.zig").Storage;
const ArrayList = std.ArrayList;
const Datetime = @import("datetime").datetime.Datetime;
const url_util = @import("url.zig");
const http = @import("http.zig");
const parse = @import("parse.zig");
const zuri = @import("zuri");
const log = std.log;

// pub const io_mode = .evented;

// TODO: how to handle displaying untagged feeds?

const Server = struct {
    const g = struct {
        var storage: *Storage = undefined;
    };
    const Self = @This();
    server: RoutezServer,

    pub fn init(storage: *Storage) Self {
        g.storage = storage;
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

        return Server{ .server = server };
    }

    fn feedAddHandler(req: Request, res: Response) !void {
        print("{}\n", .{req});
        print("{}\n", .{res});
        if (mem.eql(u8, req.method, "POST")) {
            try feedAddPost(req, res);
        } else if (mem.eql(u8, req.method, "GET")) {
            try feedAddGet(req, res);
        } else {
            // TODO: response https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/405
        }
    }

    fn feedAddGet(req: Request, res: Response) !void {
        _ = req;
        try res.write(
            \\<form action="/feed/add" method="POST">
            \\<div>
            \\<label for="feed_url">Feed/Site url</label>
            \\<input type="text" name="feed_url" id="feed_url" placeholder="Enter site or feed url" value="localhost:8080/many-links.html">
            \\</div>
            \\<div>
            \\<label for="tags">Tags</label>
            \\<input type="text" id="tags" name="tags" value="tag1, tag2, tag3">
            \\</div>
            \\<button type="submit">Add feed</button>
            \\</form>
        );
    }

    fn feedAddPost(req: Request, res: Response) !void {
        print("{s}\n", .{req.path});
        print("{s}\n", .{req.query});
        for (req.headers.list.items) |h| {
            print("{s}: {s}\n", .{ h.name, h.value });
        }
        print("{s}\n", .{req.body});
        _ = res;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try res.write("<p>Add feed</p>");
        if (try req.headers.get(arena.allocator(), "referer")) |headers| {
            print("Headers (referer): {s}\n", .{headers});
            const referer = headers[0];
            try res.print("Referer: {s}\n", .{referer.value});
        }

        // Get submitted form values
        var tags_input: []const u8 = "";
        var add_urls = try ArrayList([]const u8).initCapacity(arena.allocator(), 2);
        const body_decoded = (try zuri.Uri.decode(arena.allocator(), req.body)) orelse req.body;
        var iter = mem.split(u8, body_decoded, "&");
        while (iter.next()) |key_value| {
            var iter_key_value = mem.split(u8, key_value, "=");
            const key = iter_key_value.next() orelse continue;
            const value = iter_key_value.next() orelse continue;
            if (mem.eql(u8, "feed_url", key) or mem.eql(u8, "feed_pick", key)) {
                try add_urls.append(mem.trim(u8, value, "+"));
            } else if (mem.eql(u8, "tags", key)) {
                tags_input = value;
            }
        }
        if (add_urls.items.len == 0) {
            try res.write("No urls found\n");
            // TODO: no urls to add
            // redirect to /feed/add (GET)
            return;
        }

        for (add_urls.items) |input_url| {
            const url = try url_util.makeValidUrl(arena.allocator(), input_url);
            print("url: {s}\n", .{url});
            var resp = try http.resolveRequest(&arena, url, null, null);

            const resp_ok = switch (resp) {
                .ok => |ok| ok,
                .not_modified => {
                    log.err("resolveRequest() fn returned .not_modified union value. This should not happen when adding new feed. Input url: {s}", .{url});
                    // TODO: send somekind or http error
                    continue;
                },
                .fail => |msg| {
                    try res.print("Failed to resolve url {s}. Returned error message: {s}", .{ url, msg });
                    continue;
                },
            };

            switch (resp_ok.content_type) {
                .html => {
                    const html_data = try parse.Html.parseLinks(arena.allocator(), resp_ok.body);
                    if (html_data.links.len > 0) {
                        const tags = "TODO";
                        try res.write("<form action='/feed/add' method='POST'>");
                        { // form
                            try res.print("<p>Url: {s}</p>", .{url});
                            try res.print(
                                \\<label for="tags">Tags</label>
                                \\<input type="text" name="tags" id="tags" placeholder="Enter feed tags" value="{s}">
                            , .{tags});
                            try res.write("<fieldset><ul>");
                            { // fieldset
                                try res.write("<legend>Pick feed(s) to add</legend>");
                                for (html_data.links) |link| {
                                    const page_uri = try zuri.Uri.parse(url, true);
                                    const link_url = try url_util.makeWholeUrl(arena.allocator(), page_uri, link.href);
                                    const link_title = link.title orelse html_data.title;
                                    try res.write("<li><label>");
                                    try res.print("<input type='checkbox' name='feed_pick' value='{s}'>", .{link_url});
                                    if (link_title) |title| {
                                        try res.print("[{s}] {s} {s}", .{ link.media_type.toString(), title, link_url });
                                    } else {
                                        try res.print("[{s}] {s}", .{ link.media_type.toString(), link_url });
                                    }
                                    try res.write("</label></li>");
                                }
                            }
                            try res.write(
                                \\</ul></fieldset>
                                \\<button type="submit">Add feed(s)</button>
                            );
                        }
                        try res.write("</form>");
                    } else {
                        try res.print("<p>No feed links found in {s}", .{url});
                    }
                },
                .xml => {
                    try res.write("TODO: xml");
                },
                .xml_atom => {
                    try res.write("TODO: atom");
                },
                .xml_rss => {
                    try res.write("TODO: rss");
                },
                .json => {
                    try res.write("TODO: json");
                },
                .json_feed => {
                    try res.write("TODO: json_feed");
                },
                .unknown => {
                    try res.write("TODO: unknown");
                },
            }
        }
    }

    fn tagHandler(req: Request, res: Response, args: *const struct { tags: []const u8 }) !void {
        _ = req;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var all_tags = try g.storage.getAllTags();

        var active_tags = ArrayList([]const u8).init(allocator);
        defer active_tags.deinit();

        var it = mem.split(u8, args.tags, "+");
        while (it.next()) |tag| {
            if (hasTag(all_tags, tag)) {
                try active_tags.append(tag);
                continue;
            }
        }

        try res.write("<p>Active tags: ");
        {
            const first_tag = active_tags.items[0];
            try res.write(first_tag);
        }
        for (active_tags.items[1..]) |a_tag| {
            try res.write(",");
            try res.write(a_tag);
        }
        try res.write("</p>");

        var recent_feeds = try g.storage.getRecentlyUpdatedFeedsByTags(active_tags.items);
        try printFeeds(res, recent_feeds);

        try printTags(res, all_tags, active_tags.items);
    }

    fn hasTag(all_tags: []Storage.TagCount, tag: []const u8) bool {
        for (all_tags) |all_tag| {
            if (mem.eql(u8, tag, all_tag.name)) return true;
        }
        return false;
    }

    fn printTimestamp(res: Response, dt: Datetime) !void {
        try res.print("{d}.{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC\n", .{
            dt.date.year, dt.date.month,  dt.date.day,
            dt.time.hour, dt.time.minute, dt.time.second,
        });
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
            try res.print(" | id: {d} ", .{feed.id});
            if (feed.updated_timestamp) |timestamp| {
                try res.write(" | ");
                const dt = Datetime.fromSeconds(@intToFloat(f64, timestamp));
                try printTimestamp(res, dt);
                try res.write(" | ");
                try printElapsedTime(res, dt, now);
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
                    try printTimestamp(res, dt);
                    try res.write(" | ");
                    try printElapsedTime(res, dt, now);
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
        try printFeeds(res, recent_feeds);

        // Get tags with count
        var tags = try g.storage.getAllTags();
        try printTags(res, tags, &[_][]const u8{});
    }

    fn printTags(res: Response, tags: []Storage.TagCount, active_tags: [][]const u8) !void {
        try res.write("<ul>");
        for (tags) |tag| {
            var is_active = false;
            for (active_tags) |a_tag| {
                if (mem.eql(u8, tag.name, a_tag)) {
                    is_active = true;
                    break;
                }
            }
            if (!is_active) {
                try res.print("<li><button>{s} - {d}</button></li>", .{ tag.name, tag.count });
            } else {
                try res.print("<li>[active] <button>{s} - {d}</button></li>", .{ tag.name, tag.count });
            }
        }
        try res.write("</ul>");
    }
};

pub fn run(storage: *Storage) !void {
    print("run server\n", .{});
    var server = Server.init(storage);
    var addr = try Address.parseIp("127.0.0.1", 8282);
    try server.server.listen(addr);
}
