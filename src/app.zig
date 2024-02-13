const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Storage = @import("./storage.zig").Storage;
const feed_types = @import("./feed_types.zig");
const Feed = feed_types.Feed;
const FeedOptions = feed_types.FeedOptions;
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
const html = @import("./html.zig");

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
    // TODO: generate html file
    // html: void,
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
// const default_db_path: [:0]const u8 = "~/.config/feedgaze/database.sqlite";
pub fn Cli(comptime Writer: type, comptime Reader: type) type {
    return struct {
        allocator: Allocator,
        storage: Storage = undefined,
        out: Writer,
        in: Reader,
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
                    try self.out.print("Running in foreground\n", .{});
                    while (true) {
                        const smallest = (try self.storage.getSmallestCountdown()) orelse 1;
                        if (smallest > 0) {
                            std.time.sleep(@intCast(smallest * std.time.ns_per_s));
                            continue;
                        }
                        try self.update(null, .{});
                    }
                },
            }
        }

        fn printHelp(self: Self, verb: ?CliVerb) !void {
            var output: []const u8 =
                \\Usage: feedgaze [command] [options]
                \\
                \\Commands
                \\
                \\  add       Add feed
                \\  remove    Remove feed(s)
                \\  update    Update feed(s)
                \\  run       Run update in foreground
                \\  show      Print feeds' items
                \\  help      Print this help and exit
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

        // TODO: redo with curl
        pub fn add(self: *Self, url: []const u8) !void {
            // if (try self.storage.hasFeedWithFeedUrl(url)) {
            //     // TODO?: ask user if they want re-add feed?
            //     std.log.info("There already exists feed '{s}'", .{url});
            //     return;
            // }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            // fetch url content
            var req = try http_client.init(arena.allocator());
            defer req.deinit();
            var fetch_url = url;
            var resp = try req.fetch(fetch_url, .{});
            defer resp.deinit();

            var fallback_title: ?[]const u8 = null;
            if (resp.body.items.len == 0) {
                std.log.err("HTTP response body is empty. Request url: {s}", .{fetch_url});
                return;
            }

            var feed_options = FeedOptions.fromResponse(resp);
            var content = feed_options.body;
            var content_type = feed_options.content_type;
            if (content_type == .html) {
                const links = try html.parseHtmlForFeedLinks(arena.allocator(), content);
                if (links.len == 0) {
                    std.log.info("Found no feed links", .{});
                    return;
                }

                const index = if (links.len > 1) try getUserInput(links, self.out, self.in) else 0;
                const link = links[index];

                fallback_title = link.title;
                var buf: [128]u8 = undefined;
                var fixed_buf = std.io.fixedBufferStream(&buf);
                if (link.link[0] == '/') {
                    var uri = try std.Uri.parse(url);
                    uri.path = link.link;
                    try uri.format("", .{}, fixed_buf.writer());
                    fetch_url = fixed_buf.getWritten();
                } else {
                    fetch_url = link.link;
                }
                var resp_2 = try req.fetch(fetch_url, .{});
                defer resp_2.deinit();

                if (resp_2.body.items.len == 0) {
                    std.log.err("HTTP response body is empty. Request url: {s}", .{fetch_url});
                    return;
                }

                feed_options = FeedOptions.fromResponse(resp_2);
                content = feed_options.body;
                content_type = feed_options.content_type;
                if (content_type == .html) {
                    // NOTE: should not happen
                    std.log.err("Got unexpected content type 'html' from response. Expected 'atom' or 'rss'.", .{});
                    return;
                }
                self.storage.addFeed(&arena, feed_options, fetch_url, fallback_title) catch |err| switch (err) {
                    error.NothingToInsert => {
                        std.log.info("No items added to feed '{s}'", .{fetch_url});
                    },
                    error.FeedExists => {
                        std.log.info("Feed '{s}' already exists", .{fetch_url});
                    },
                    else => return err,
                };

            } else {
                self.storage.addFeed(&arena, feed_options, fetch_url, fallback_title) catch |err| switch (err) {
                    error.NothingToInsert => {
                        std.log.info("No items added to feed '{s}'", .{fetch_url});
                    },
                    error.FeedExists => {
                        std.log.info("Feed '{s}' already exists", .{fetch_url});
                    },
                    else => return err,
                };
            }
        }

        fn getUserInput(links: []html.FeedLink, writer: Writer, reader: Reader) !usize {
            for (links, 1..) |link, i| {
                try writer.print("{d}. {s} | {s}\n", .{i, link.title orelse "<no-title>", link.link});
            }
            var buf: [32]u8 = undefined;
            var fix_buf = std.io.fixedBufferStream(&buf);
            var index: usize = 0;

            while (index == 0 or index > links.len) {
                fix_buf.reset();
                try writer.writeAll("Enter number: ");
                try reader.streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len);
                const value = mem.trim(u8, fix_buf.getWritten(), &std.ascii.whitespace);
                index = std.fmt.parseUnsigned(usize, std.mem.trim(u8, value, &std.ascii.whitespace), 10) catch {
                    std.log.err("Provide input is not a number. Enter number between 1 - {d}", .{links.len});
                    continue;
                };
                if (index == 0 or index > links.len) {
                    std.log.err("Invalid number input. Have to enter number between 1 - {d}", .{links.len});
                    continue;
                }
            }
            return index - 1;
        }

        pub fn update(self: *Self, input: ?[]const u8, options: UpdateOptions) !void {
            if (input == null) {
                std.log.info("Updating all feeds", .{});
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            if (!options.force) {
                // TODO: only update feeds that were updated in for loop?
                try self.storage.updateCountdowns();
            }
            const feed_updates = try self.storage.getFeedsToUpdate(arena.allocator(), input, options);
            std.log.info("Updating {d} feed(s).", .{feed_updates.len});

            var item_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer item_arena.deinit();

            for (feed_updates) |f_update| {
                _ = item_arena.reset(.retain_capacity);
                std.log.info("Updating feed '{s}'", .{f_update.feed_url});
                var req = http_client.init(item_arena.allocator()) catch |err| {
                    std.log.err("Failed to fetch feed '{s}'. Error: {}\n", .{f_update.feed_url, err});
                    continue;
                }; 
                defer req.deinit();
                
                const resp = req.fetch(f_update.feed_url, .{
                    .etag = f_update.etag,
                    .last_modified_utc = f_update.last_modified_utc,
                }) catch |err| {
                    std.log.err("Failed to fetch feed '{s}'. Error: {}\n", .{f_update.feed_url, err});
                    continue;
                };
                defer resp.deinit();

                if (resp.status_code == 304) {
                    try self.storage.updateLastUpdate(f_update.feed_id);
                    std.log.info("Nothing to update in '{s}'\n", .{f_update.feed_url});
                    continue;
                }

                self.storage.updateFeedAndItems(&item_arena, resp, f_update) catch |err| switch (err) {
                    error.NothingToInsert => {
                        std.log.info("No items added to feed '{s}'\n", .{f_update.feed_url});
                        continue;
                    },
                    error.NoHtmlParse => {
                        std.log.err("Failed to update feed '{s}'. Update should not return html file.\n", .{f_update.feed_url});
                        continue;
                    },
                    else => {
                        std.log.err("Failed to update feed '{s}'. Error: {}\n", .{f_update.feed_url, err});
                        continue;
                    }
                };
                std.log.info("Updated feed '{s}'\n", .{f_update.feed_url});
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

            var buf: [16]u8 = undefined;
            var fix_buf = std.io.fixedBufferStream(&buf);

            for (feeds) |feed| {
                while (true) {
                    fix_buf.reset();
                    try self.out.print("Delete feed '{s}' (Y/N)? ", .{feed.feed_url});
                    self.in
                        .streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len) catch |err| switch (err) {
                            error.StreamTooLong => {},
                            else => return err,
                        };
                    const value = mem.trim(u8, fix_buf.getWritten(), &std.ascii.whitespace);

                    // Empty stdin
                    var len = fix_buf.getWritten().len;
                    while (len == buf.len and buf[len-1] != '\n') {
                        len = try self.in.read(&buf);
                    }
                
                    if (value.len == 1) {
                        if (value[0] == 'y' or value[0] == 'Y') {
                            try self.storage.deleteFeed(feed.feed_id);
                            try self.out.print("Removed feed '{s}'\n", .{feed.feed_url});
                            break;
                        } else if (value[0] == 'n' or value[0] == 'N') {
                            break;
                        }
                    }
                    try self.out.print("Invalid user input. Retry\n", .{});
                }
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
    const fb_writer = fb.writer();
    const CliTest = Cli(@TypeOf(fb_writer));
    var app_cli = CliTest{
        .allocator = std.testing.allocator,
        .out = fb_writer,
    };

    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    const test_dir_path = "./test/";
    const test_filename = "feedgaze_show.db";
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
    const fb_writer = fb.writer();
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
