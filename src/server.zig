const std = @import("std");
const mem = std.mem;
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

// pub const io_mode = .evented;

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
                // routez.all("/settings", settingsHandler),
                routez.all("/tag/{tags}", tagHandler),
                // routez.get("/about", aboutHandler),
            },
        );
        // Don't get any address in use error messages
        if (builtin.mode == .Debug) server.server.reuse_address = true;

        return Server{ .server = server };
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
        try printTags(res, tags);
    }

    // TODO: which are active tags
    fn printTags(res: Response, tags: []Storage.TagCount) !void {
        try res.write("<ul>");
        for (tags) |tag| {
            try res.print("<li>{s} - {d}</li>", .{ tag.name, tag.count });
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
