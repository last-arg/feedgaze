const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Storage = @import("./storage.zig").Storage;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedItem = feed_types.FeedItem;
const FeedUpdate = feed_types.FeedUpdate;
const FeedToUpdate = feed_types.FeedToUpdate;
const print = std.debug.print;
const parse = @import("./app_parse.zig");
const FeedAndItems = parse.FeedAndItems;
const ContentType = parse.ContentType;
const builtin = @import("builtin");
const args_parser = @import("zig-args");
const ShowOptions = feed_types.ShowOptions;
const UpdateOptions = feed_types.UpdateOptions;
const FetchOptions = feed_types.FetchOptions;
const fs = std.fs;

pub const Response = struct {
    feed_update: FeedUpdate,
    content: []const u8,
    content_type: ContentType,
    location: []const u8,
};

const CliVerb = union(enum) {
    add: void,
    remove: void,
    show: ShowOptions,
    update: UpdateOptions,
    run: void,
};

const CliGlobal = struct {
    database: ?[:0]const u8 = null,
    help: bool = false,

    pub const shorthands = .{
        .h = "help",
        .d = "database",
    };
};

const default_db_path: [:0]const u8 = "tmp/db_feedgaze.sqlite";
pub fn Cli(comptime Writer: type, comptime HttpRequest: type) type {
    return struct {
        allocator: Allocator,
        storage: ?Storage = null,
        clean_opts: Storage.CleanOptions = .{},
        out: Writer,
        const Self = @This();

        pub fn run(self: *Self) !void {
            var args = try args_parser.parseWithVerbForCurrentProcess(CliGlobal, CliVerb, self.allocator, .print);
            defer args.deinit();

            if (args.options.help) {
                try self.printHelp(args.verb);
                return;
            }

            const verb = args.verb orelse {
                return;
            };

            if (self.storage == null) {
                try self.connectDatabase(args.options.database);
            }

            switch (verb) {
                .add => {
                    if (args.positionals.len > 0) {
                        for (args.positionals) |url| {
                            try self.add(url);
                        }
                    } else {
                        std.log.err("'add' subcommand requires feed url.\nExample: feedgaze add <url>", .{});
                    }
                },
                .remove => {
                    if (args.positionals.len > 0) {
                        for (args.positionals) |url| {
                            try self.remove(url);
                        }
                    } else {
                        std.log.err("'remove' subcommand requires search term (feed url).\nExample: feedgaze remove <url>", .{});
                    }
                },
                .show => |opts| {
                    try self.show(args.positionals, opts);
                },
                .update => |opts| {
                    const input = if (args.positionals.len > 0) args.positionals[0] else null;
                    try self.update(input, opts);
                },
                .run => {
                    std.debug.print("TODO: run foreground", .{});
                },
            }
        }

        fn printHelp(self: Self, verb: ?CliVerb) !void {
            // TODO: use stderr instead?
            var output: []const u8 =
                \\Usage: feedgaze [command] [options]
                \\
                \\Commands
                \\
                \\  add       Add feed
                \\  remove    Remove feed(s)
                \\  update    Update feed(s)
                \\  help      Print this help and exit
                \\  run       Run update in foreground
                \\
                \\General options:
                \\
                \\  -h, --help        Print command-specific usage
                \\  -d, --database    Set database to use 
                \\
                \\
            ;

            if (verb) |v| {
                output = switch (v) {
                    .add =>
                    \\Usage: feedgaze add <url> [options]
                    \\
                    \\  Add feed. Requires url to feed.
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                    \\
                    ,
                    .remove =>
                    \\Usage: feedgaze remove <search_term> [options]
                    \\
                    \\  Remove feed. Requires search term. Search term will match page or feed url. 
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                    \\
                    ,
                    .show =>
                    \\Usage: feedgaze show [search_term] [options]
                    \\
                    \\  Show feed(s). Optional search term. Search term will match page or feed url. 
                    \\  Orders feeds by latest updated.
                    \\
                    \\Options:
                    \\  -h, --help      Print this help and exit
                    \\  -l, --limit     Set limit how many feeds to show
                    \\  --item-limit    Set limit how many feed items to show
                    ,
                    .update =>
                    \\Usage: feedgaze update [search_term] [options]
                    \\
                    \\  Update feed(s). Optional search term. Search term will match page or feed url. 
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                    \\  --force       Will force update all matched feeds
                    ,
                    .run =>
                    \\Usage: feedgaze run [options]
                    \\
                    \\  Auto update feeds in the foreground. 
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                    ,
                };
            }

            _ = try self.out.write(output);
        }

        pub fn connectDatabase(self: *Self, path: ?[:0]const u8) !void {
            const db_path = blk: {
                const db_path = path orelse default_db_path;
                if (db_path.len == 0) {
                    std.log.err("'--database' requires filepath input.", .{});
                }
                if (std.mem.eql(u8, ":memory:", db_path)) {
                    break :blk null;
                }
                if (std.mem.endsWith(u8, db_path, std.fs.path.sep_str)) {
                    std.log.err("'--database' requires filepath, diretory path was provided.", .{});
                    return;
                }

                var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
                const db_dir = fs.path.dirname(db_path) orelse {
                    std.log.err("Invalid '--database' directory input", .{});
                    return;
                };
                _ = fs.cwd().realpath(db_dir, &path_buf) catch |err| switch (err) {
                    error.FileNotFound => {
                        try fs.cwd().makePath(db_dir);
                    },
                    else => return error.NODS,
                };
                break :blk db_path;
            };

            self.storage = Storage.init(db_path) catch |err| {
                if (db_path) |p| {
                    std.log.err("Failed to open database file '{s}'.", .{p});
                } else {
                    std.log.err("Failed to open database in memory.", .{});
                }
                return err;
            };
        }

        pub fn add(self: *Self, url: []const u8) !void {
            if (try self.storage.?.hasFeedWithFeedUrl(url)) {
                std.log.info("There already exists feed '{s}'", .{url});
                return;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            // fetch url content
            const parsed_url = try std.Uri.parse(url);
            var client = std.http.Client{ .allocator = arena.allocator() };
            defer client.deinit();
            var fr = try HttpRequest.init(&client, parsed_url, .{});
            defer fr.deinit();

            const content = try fr.getBody(arena.allocator());
            const content_type = ContentType.fromString(fr.request.response.headers.getFirstValue("content-type") orelse "");
            var parsed = try parse.parse(arena.allocator(), content, content_type);
            if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
                parsed.feed.updated_raw = parsed.items[0].updated_raw;
            }
            try parsed.feed.prepareAndValidate(url);
            const feed_id = try self.storage.?.insertFeed(parsed.feed);
            try FeedItem.prepareAndValidateAll(parsed.items, feed_id);
            _ = try self.storage.?.insertFeedItems(parsed.items);
            try self.storage.?.updateFeedUpdate(feed_id, FeedUpdate.fromHeaders(fr.request.response.headers));
        }

        pub fn update(self: *Self, input: ?[]const u8, options: UpdateOptions) !void {
            if (input == null) {
                std.log.info("Updating all feeds", .{});
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            if (!options.force) {
                try self.storage.?.updateCountdowns();
            }
            const feed_updates = try self.storage.?.getFeedsToUpdate(arena.allocator(), input, options);

            var client = std.http.Client{ .allocator = arena.allocator() };
            defer client.deinit();

            for (feed_updates) |f_update| {
                const parsed_url = try std.Uri.parse(f_update.feed_url);
                var fr = try HttpRequest.init(&client, parsed_url, .{
                    .etag = f_update.etag,
                    .last_modified_utc = f_update.last_modified_utc,
                });

                const content = try fr.getBody(arena.allocator());
                const content_type = ContentType.fromString(fr.request.response.headers.getFirstValue("content-type") orelse "");
                var parsed = try parse.parse(arena.allocator(), content, content_type);

                if (parsed.feed.updated_raw == null and parsed.items.len > 0) {
                    parsed.feed.updated_raw = parsed.items[0].updated_raw;
                }

                parsed.feed.feed_id = f_update.feed_id;
                try parsed.feed.prepareAndValidate(f_update.feed_url);
                try self.storage.?.updateFeed(parsed.feed);

                // Update feed items
                try FeedItem.prepareAndValidateAll(parsed.items, f_update.feed_id);
                try self.storage.?.updateAndRemoveFeedItems(parsed.items, self.clean_opts);

                // Update feed_update
                try self.storage.?.updateFeedUpdate(f_update.feed_id, FeedUpdate.fromHeaders(fr.request.response.headers));
                std.log.info("Updated feed '{s}'", .{f_update.feed_url});
            }
        }

        pub fn remove(self: *Self, url: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feeds = try self.storage.?.getFeedsWithUrl(arena.allocator(), url);
            if (feeds.len == 0) {
                std.log.info("Found no feeds for <url> input '{s}'", .{url});
                return;
            }

            for (feeds) |feed| {
                // TODO?: prompt user for to confirm deletion
                try self.storage.?.deleteFeed(feed.feed_id);
                std.log.info("Removed feed '{s}'", .{feed.feed_url});
            }
        }

        pub fn show(self: *Self, inputs: [][]const u8, opts: ShowOptions) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feeds = try self.storage.?.getLatestFeedsWithUrl(arena.allocator(), inputs, opts);

            for (feeds) |feed| {
                const title = feed.title orelse "<no title>";
                const url_out = feed.page_url orelse feed.feed_url;
                _ = try self.out.print("{s} - {s}\n", .{ title, url_out });
                const items = try self.storage.?.getLatestFeedItemsWithFeedId(arena.allocator(), feed.feed_id, opts);
                if (items.len == 0) {
                    _ = try self.out.write("  ");
                    _ = try self.out.write("Feed has no items.");
                    continue;
                }

                for (items) |item| {
                    // _ = try self.out.print("{d}. ", .{item.item_id.?});
                    _ = try self.out.print("\n  {s}\n  {s}\n", .{ item.title, item.link orelse "<no link>" });
                }
                _ = try self.out.write("\n");
            }
        }
    };
}

const http_client = @import("./http_client.zig");
test "cli.run" {
    std.testing.log_level = .debug;

    if (@import("builtin").target.os.tag != .linux) {
        std.log.info("Need to run tests on Linux", .{});
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cmd = "feedgaze".*;
    // var storage = try Storage.init("/media/hdd/code/feedgaze/tmp/db/fg.sqlite");
    var buf: [4 * 1024]u8 = undefined;
    var fb = std.io.fixedBufferStream(&buf);
    var fb_writer = fb.writer();
    // const CliTest = Cli(@TypeOf(fb_writer), FeedRequest);
    const CliTest = Cli(@TypeOf(fb_writer), http_client.TestRequest);
    var app_cli = CliTest{
        .allocator = arena.allocator(),
        .out = fb_writer,
    };
    var storage: Storage = undefined;

    var db_flag = "--database".*;
    var db_input = ":memory:".*;
    // var db_input = "tmp/h/hello.db".*;
    // var input = "http://localhost:8282/rss2.xml".*;
    var input = "http://localhost:8282/rss2".*;
    {
        http_client.TestRequest.text = @embedFile("rss2.xml");
        var add_cmd = "add".*;
        var argv = [_][*:0]u8{ &cmd, &db_flag, &db_input, &add_cmd, &input };
        std.os.argv = &argv;
        try app_cli.run();
        storage = app_cli.storage.?;

        const feeds = try storage.getFeedsWithUrl(arena.allocator(), &input);
        try std.testing.expectEqual(@as(usize, 1), feeds.len);
        const feed = feeds[0];
        var expect = try parse.parseRss(arena.allocator(), @embedFile("rss2.xml"));
        try expect.feed.prepareAndValidate(&input);
        expect.feed.feed_id = 1;
        try std.testing.expectEqualDeep(expect.feed, feed);
        const items = try storage.getFeedItemsWithFeedId(arena.allocator(), feed.feed_id);
        try std.testing.expectEqual(@as(usize, 3), items.len);
    }

    {
        // Show feeds and items
        // feedgaze show [<url>] [--limit]
        // - will show latest updated feeds first
        var show_cmd = "show".*;
        var argv = [_][*:0]u8{ &cmd, &show_cmd, &input };
        std.os.argv = &argv;
        try app_cli.run();
        const r = fb.getWritten();
        // print("|{s}|\n", .{fb.getWritten()});
        const expect =
            \\Liftoff News - http://liftoff.msfc.nasa.gov/
            \\
            \\  Star City's Test
            \\  http://liftoff.msfc.nasa.gov/news/2003/news-starcity.asp
            \\
            \\  Sky watchers in Europe, Asia, and parts of Alaska and Canada will experience a <a href="http://science.nasa.gov/headlines/y2003/30may_solareclipse.htm">partial eclipse of the Sun</a> on Saturday, May 31st.
            \\  <no link>
            \\
            \\  Third title
            \\  <no link>
            \\
            \\
        ;
        try std.testing.expectEqualStrings(expect, r);
    }

    {
        // Update feed
        // feedgaze update <url> [--force]
        // - check if feed with <url> exists
        // - if not --force
        //   - see if feed needs updating
        // - update if needed
        var subcmd = "update".*;
        var argv = [_][*:0]u8{ &cmd, &subcmd, &input };
        std.os.argv = &argv;
        try app_cli.run();
        var items = try storage.getLatestFeedItemsWithFeedId(arena.allocator(), 1, .{});
        try std.testing.expectEqual(@as(usize, 3), items.len);

        app_cli.clean_opts.max_item_count = 2;
        try app_cli.run();
        app_cli.clean_opts.max_item_count = 10;
        const items1 = try storage.getLatestFeedItemsWithFeedId(arena.allocator(), 1, .{});

        try std.testing.expectEqual(@as(usize, 2), items1.len);
        try std.testing.expectEqual(@as(usize, 1), items1[0].item_id.?);
        try std.testing.expectEqual(@as(usize, 2), items1[1].item_id.?);

        // Delete first item (newest/latest)
        try storage.sql_db.exec("DELETE FROM item WHERE item_id = 1", .{}, .{});

        try app_cli.run();
        var items2 = try storage.getLatestFeedItemsWithFeedId(arena.allocator(), 1, .{});
        try std.testing.expectEqual(@as(usize, 3), items2.len);
        // NOTE: can use 'expectEqualDeep' to compare slices.
        for (items, items2) |*item, *item2| {
            item.item_id = null;
            item2.item_id = null;
        }
        try std.testing.expectEqualDeep(items2, items);
    }

    {
        var remove_cmd = "remove".*;
        var argv = [_][*:0]u8{ &cmd, &remove_cmd, &input };
        std.os.argv = &argv;
        try app_cli.run();

        const feeds = try storage.getFeedsWithUrl(arena.allocator(), &input);
        try std.testing.expectEqual(@as(usize, 0), feeds.len);
        var item_count = @import("./storage.zig").one(&storage.sql_db, usize, "select count(*) from item;", .{}) catch unreachable;
        try std.testing.expectEqual(@as(usize, 0), item_count.?);
    }
}

test "feedgaze.run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cmd = "feedgaze".*;
    // var storage = try Storage.init("/media/hdd/code/feedgaze/tmp/db/fg.sqlite");
    var buf: [4 * 1024]u8 = undefined;
    var fb = std.io.fixedBufferStream(&buf);
    var fb_writer = fb.writer();
    // const CliTest = Cli(@TypeOf(fb_writer), FeedRequest);

    const CliTest = Cli(@TypeOf(fb_writer), http_client.TestRequest);
    var app_cli = CliTest{
        .allocator = arena.allocator(),
        .out = fb_writer,
    };

    {
        var run_cmd = "run".*;
        var argv = [_][*:0]u8{ &cmd, &run_cmd };
        std.os.argv = &argv;
        try app_cli.run();
    }
}
