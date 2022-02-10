const std = @import("std");
const builtin = @import("builtin");
const routez = @import("routez");
const RoutezServer = routez.Server;
const Request = routez.Request;
const Response = routez.Response;
const print = std.debug.print;
const allocator = std.heap.page_allocator;
const Address = std.net.Address;
const Storage = @import("feed_db.zig").Storage;

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
                // routez.get("/about", aboutHandler),
            },
        );
        // Don't get any address in use error messages
        if (builtin.mode == .Debug) server.server.reuse_address = true;

        return Server{ .server = server };
    }

    // Index displays most recenlty update feeds
    fn indexHandler(req: Request, res: Response) !void {
        _ = req;
        // Get most recently update feeds
        var recent_feeds = try g.storage.getRecentlyUpdatedFeeds();
        try res.write("<ul>");
        for (recent_feeds) |feed| {
            try res.write("<li>");
            if (feed.link) |link| {
                try res.print("<a href=\"{s}\">{s}</a>", .{ link, feed.title });
            } else {
                try res.print("{s}", .{feed.title});
            }
            try res.print(" | id: {d}. ", .{feed.id});
            if (feed.updated_timestamp) |timestamp| {
                try res.print(" | timestamp: {d}", .{timestamp});
            }
            try res.write("</li>");
        }
        try res.write("</ul>");

        // Get tags with count
        var tags = try g.storage.getAllTags();
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
