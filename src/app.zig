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
const FetchOptions = feed_types.FetchHeaderOptions;
const fs = std.fs;
const http_client = @import("./http_client.zig");

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
pub fn Cli(comptime Writer: type) type {
    return struct {
        allocator: Allocator,
        // TODO: can make storage field probably not optional (remove null)
        storage: Storage = undefined,
        out: Writer,
        const Self = @This();

        // TODO: pass 'args' as parameter to function? Makes testing also easier.
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

            self.storage = try connectDatabase(args.options.database);

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
                \\  show      Print feeds' items
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

        pub fn add(self: *Self, url: []const u8) !void {
            if (try self.storage.hasFeedWithFeedUrl(url)) {
                // TODO?: ask user if they want re-add feed?
                std.log.info("There already exists feed '{s}'", .{url});
                return;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            // fetch url content
            var req = try http_client.init(arena.allocator(), .{});
            defer req.deinit();
            var fetch_url = url;
            var resp = try req.fetch(fetch_url);
            defer resp.deinit();

            var fallback_title: ?[]const u8 = null;
            if (resp.body == null or resp.body.?.len == 0) {
                std.log.err("HTTP response body is empty. Request url: {s}", .{fetch_url});
                return;
            }
            var content = resp.body.?;
            var headers  = resp.headers;
            var content_type = ContentType.fromString(resp.headers.getFirstValue("content-type") orelse "");
            if (content_type == .html) {
                const links = try http_client.parseHtmlForFeedLinks(arena.allocator(), content);
                if (links.len == 0) {
                    std.log.info("Found no feed links", .{});
                    return;
                }

                const link = blk: {
                    if (links.len > 1) {
                        for (links, 1..) |link, i| {
                            print("{d}. {s} | {s}\n", .{i, link.title orelse "<no-title>", link.link});
                        }
                        // TODO: ask user input when there is more than one 
                        // possible feeds to add
                    }
                    
                    break :blk links[0];
                };


                fallback_title = link.title;
                fetch_url = link.link;
                var resp_2 = try req.fetch(fetch_url);
                defer resp_2.deinit();

                if (resp_2.body == null or resp_2.body.?.len == 0) {
                    std.log.err("HTTP response body is empty. Request url: {s}", .{fetch_url});
                    return;
                }
                content = resp_2.body.?;
                headers = resp_2.headers;

                content_type = ContentType.fromString(resp_2.headers.getFirstValue("content-type") orelse "");
                if (content_type == .html) {
                    // NOTE: should not happen
                    std.log.err("Got unexpected content type 'html' from response. Expected 'atom' or 'rss'.", .{});
                    return;
                }
                try self.storage.addFeed(&arena, content, content_type, url, headers, fallback_title);
            } else {
                try self.storage.addFeed(&arena, content, content_type, url, headers, fallback_title);
            }
        }

        pub fn update(self: *Self, input: ?[]const u8, options: UpdateOptions) !void {
            if (input == null) {
                std.log.info("Updating all feeds", .{});
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            if (!options.force) {
                try self.storage.updateCountdowns();
            }
            const feed_updates = try self.storage.getFeedsToUpdate(arena.allocator(), input, options);

            for (feed_updates) |f_update| {
                var req = try http_client.init(arena.allocator(), .{});
                defer req.deinit();
                var resp = try req.fetch(f_update.feed_url);
                defer resp.deinit();

                const content = resp.body orelse {
                    std.log.err("HTTP response body is empty. Request url: {s}", .{f_update.feed_url});
                    return;
                };
                const content_type = ContentType.fromString(resp.headers.getFirstValue("content-type") orelse "");

                try self.storage.updateFeedAndItems(&arena, content, content_type, f_update, resp.headers);
                std.log.info("Updated feed '{s}'", .{f_update.feed_url});
            }
        }

        pub fn remove(self: *Self, url: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feeds = try self.storage.getFeedsWithUrl(arena.allocator(), url);
            if (feeds.len == 0) {
                std.log.info("Found no feeds for <url> input '{s}'", .{url});
                return;
            }

            for (feeds) |feed| {
                // TODO?: prompt user for to confirm deletion
                try self.storage.deleteFeed(feed.feed_id);
                std.log.info("Removed feed '{s}'", .{feed.feed_url});
            }
        }

        pub fn show(self: *Self, inputs: [][]const u8, opts: ShowOptions) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const feeds = try self.storage.getLatestFeedsWithUrl(arena.allocator(), inputs, opts);

            for (feeds) |feed| {
                const title = feed.title orelse "<no title>";
                const url_out = feed.page_url orelse feed.feed_url;
                _ = try self.out.print("{s} - {s}\n", .{ title, url_out });
                const items = try self.storage.getLatestFeedItemsWithFeedId(arena.allocator(), feed.feed_id, opts);
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

pub fn connectDatabase(path: ?[:0]const u8) !Storage {
    const db_path = blk: {
        const db_path = path orelse default_db_path;
        if (db_path.len == 0) {
            std.log.err("'--database' requires filepath input.", .{});
        }
        if (std.mem.eql(u8, ":memory:", db_path)) {
            break :blk null;
        }
        if (std.mem.endsWith(u8, db_path, std.fs.path.sep_str)) {
            return error.DirectoryPath;
        }

        if (fs.path.dirname(db_path)) |db_dir| {
            var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
            _ = fs.cwd().realpath(db_dir, &path_buf) catch |err| switch (err) {
                error.FileNotFound => {
                    try fs.cwd().makePath(db_dir);
                },
                else => return err,
            };
        }
        break :blk db_path;
    };

    return try Storage.init(db_path);
}

test "feedgaze.remove" {
    var buf: [4 * 1024]u8 = undefined;
    var fb = std.io.fixedBufferStream(&buf);
    var fb_writer = fb.writer();
    const CliTest = Cli(@TypeOf(fb_writer));
    var app_cli = CliTest{
        .allocator = std.testing.allocator,
        .out = fb_writer,
    };

    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    var test_dir_path = "./test/";
    var test_filename = "feedgaze_show.db";
    var abs_path = try fs.cwd().realpath(test_dir_path, &path_buf);
    const test_dir = try fs.openDirAbsolute(abs_path, .{});

    const tmp_dir_path = "./tmp/";
    abs_path = try fs.cwd().realpath(tmp_dir_path, &path_buf);
    const tmp_dir = try fs.openDirAbsolute(abs_path, .{});
    try test_dir.copyFile(test_filename, tmp_dir, test_filename, .{});
    var cmd = "feedgaze".*;
    var sub_cmd = "remove".*;
    var value = "localhost".*;
    // Filled with data from ./test/rss2.xml
    var db_key = "--database".*;
    const db_path = tmp_dir_path ++ test_filename;
    // var db_path = "./tmp/feedgaze_show.db".*;
    var argv = [_][*:0]u8{ &cmd, &sub_cmd, &value, &db_key, db_path };

    std.os.argv = &argv;
    try app_cli.run();
    {
        const count = try app_cli.storage.sql_db.one(usize, "select count(*) from feed", .{}, .{});
        try std.testing.expectEqual(@as(usize, 0), count.?);
    }

    {
        const count = try app_cli.storage.sql_db.one(usize, "select count(*) from item", .{}, .{});
        try std.testing.expectEqual(@as(usize, 0), count.?);
    }
}

test "feedgaze.show" {
    var buf: [4 * 1024]u8 = undefined;
    var fb = std.io.fixedBufferStream(&buf);
    var fb_writer = fb.writer();
    const CliTest = Cli(@TypeOf(fb_writer));
    var app_cli = CliTest{
        .allocator = std.testing.allocator,
        .out = fb_writer,
    };

    var cmd = "feedgaze".*;
    var sub_cmd = "show".*;
    var db_key = "--database".*;
    // Filled with data from ./test/rss2.xml
    var db_value = "./test/feedgaze_show.db".*;
    var argv = [_][*:0]u8{ &cmd, &sub_cmd, &db_key, &db_value };
    std.os.argv = &argv;
    try app_cli.run();

    const output = fb.getWritten();
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
    try std.testing.expectEqualStrings(expect, output);  
}
