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
const TagOptions = feed_types.TagOptions;
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
    remove: void,
    show: ShowOptions,
    update: UpdateOptions,
    run: void,
    server: void,
    tag: TagOptions,
    add: feed_types.AddOptions,
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
                .tag => |opts| {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();

                    if (opts.list) {
                        const tags = try self.storage.tags_all(arena.allocator());

                        if (tags.len == 0) {
                            try self.out.print("There are no tags.\n", .{});
                        }

                        for (tags) |tag| {
                            try self.out.writeAll(tag);
                        }
                        return;
                    }

                    if (args.positionals.len == 0) {
                        try self.out.print("No tags to add. Please add tags you want to add.\n", .{});
                        return;
                    }

                    var tags_arr = try std.ArrayList([]const u8).initCapacity(arena.allocator(), args.positionals.len);
                    defer tags_arr.deinit();
                    for (args.positionals) |tag| {
                        const trimmed = mem.trim(u8, tag, &std.ascii.whitespace);
                        if (trimmed.len > 0) {
                            tags_arr.appendAssumeCapacity(trimmed);
                        }
                    }

                    if (opts.feed) |input| {
                        const feeds = try self.storage.feeds_search(arena.allocator(), input, null);
                        if (feeds.len > 0) {
                            if (!opts.remove) {
                                // TODO: validate tags
                                try self.storage.tags_add(tags_arr.items);
                            }
                            const tags_ids_buf = try arena.allocator().alloc(usize, tags_arr.items.len);
                            const tags_ids = try self.storage.tags_ids(tags_arr.items, tags_ids_buf);

                            if (opts.remove) {
                                for (feeds) |feed| {
                                    try self.storage.tags_feed_remove(feed.feed_id, tags_ids);
                                }
                                try self.out.print("Removed tags from {d} feed(s).\n", .{feeds.len});
                            } else {
                                for (feeds) |feed| {
                                    try self.storage.tags_feed_add(feed.feed_id, tags_ids);
                                }
                                try self.out.print("Added tags to {d} feed(s).\n", .{feeds.len});
                            }
                        } else {
                            try self.out.print("Found no feeds to add or remove tags.\n", .{});
                        }
                        return;
                    }

                    if (opts.remove) {
                        try self.storage.tags_remove(tags_arr.items);
                        return;
                    }

                    // TODO: validate tags
                    // Validate after remove? Because there might be some
                    // invalid tags in storage. Might have invalid tags
                    // because might have changed what is valid and what not.
                    //
                    // Valid tag symbols:
                    // - A-z, 0-9
                    // - no space
                    
                    try self.storage.tags_add(tags_arr.items);
                },
                .add => |opts| {
                    if (args.positionals.len == 0) {
                        try self.out.print("Please enter valid input you want to add or modify.\n", .{});
                        return;
                    }

                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    
                    // TODO: search more than one value?
                    var tags_ids: []usize = &.{};

                    if (opts.tags) |tags_raw| {
                        var tags_iter = mem.splitScalar(u8, tags_raw, ',');
                        const cap = mem.count(u8, tags_raw, ",") + 1;
                        var tags_arr = try std.ArrayList([]const u8).initCapacity(arena.allocator(), cap);
                        defer tags_arr.deinit();
                        while (tags_iter.next()) |tag| {
                            const trimmed = mem.trim(u8, tag, &std.ascii.whitespace);
                            if (trimmed.len > 0) {
                                tags_arr.appendAssumeCapacity(trimmed);
                            }
                        }

                        // make sure all tags exist in db/stroage
                        try self.storage.tags_add(tags_arr.items);

                        // get tags' ids
                        const tags_ids_buf = try arena.allocator().alloc(usize, cap);
                        tags_ids = try self.storage.tags_ids(tags_arr.items, tags_ids_buf);
                    }

                    for (args.positionals) |input| {
                        const feed_id = self.add(input) catch |err| switch (err) {
                            error.InvalidUri => {
                                try self.out.print("Invalid input '{s}'\n", .{input});
                                continue;
                            },
                            error.FeedExists => {
                                try self.out.print("There already exists feed '{s}'\n", .{input});
                                continue;
                            },
                            else => {
                                std.log.err("Error with input '{s}'. Error message: {}", .{input, err});
                                return err;
                            }
                        };
                        try self.storage.tags_feed_add(feed_id, tags_ids);
                    }
                },
                .server => try server(),
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
                    .server => 
                    \\Usage: feedgaze server [options]
                    \\
                    \\  Launches server
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                    ,
                    .tag => 
                    \\Usage: feedgaze tag [options]
                    \\
                    \\  Add remove tags
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                    ,
                    .add => 
                    \\Usage: feedgaze add [options] <input>
                    \\
                    \\  Add, modify feeds
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                };
            }

            _ = try self.out.write(output);
        }

        pub fn add(self: *Self, url: []const u8) !usize {
            _ = std.Uri.parse(url) catch {
                return error.InvalidUri;
            };
            if (try self.storage.hasFeedWithFeedUrl(url)) {
                return error.FeedExists;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            // fetch url content
            var req = try http_client.init(arena.allocator());
            defer req.deinit();
            var fetch_url = url;
            var resp = try req.fetch(fetch_url, .{});
            defer resp.deinit();

            if (resp.body.?.items.len == 0) {
                std.log.err("HTTP response body is empty. Request url: {s}", .{fetch_url});
                return error.EmptyBody;
            }

            var feed_options = FeedOptions.fromResponse(resp);
            if (feed_options.content_type == .html) {
                feed_options.content_type = parse.getContentType(feed_options.body) orelse .html;
            }
            if (feed_options.content_type == .html) {
                const links = try html.parseHtmlForFeedLinks(arena.allocator(), feed_options.body);
                if (links.len == 0) {
                    std.log.info("Found no feed links", .{});
                    return error.NoFeedLinksInHtml;
                }

                const index = if (links.len > 1) try getUserInput(links, self.out, self.in) else 0;
                const link = links[index];

                if (!mem.startsWith(u8, link.link, "http")) {
                    var url_uri = try std.Uri.parse(url);
                    const link_buf = try arena.allocator().alloc(u8, url.len + link.link.len + 1);
                    const result = try url_uri.resolve_inplace(link.link, link_buf);
                    fetch_url = try std.fmt.allocPrint(arena.allocator(), "{}", .{result});
                } else {
                    fetch_url = link.link;
                }

                // Need to create new curl request
                var req_2 = try http_client.init(arena.allocator());
                defer req_2.deinit();

                var resp_2 = try req.fetch(fetch_url, .{});
                defer resp_2.deinit();

                if (resp_2.body.?.items.len == 0) {
                    std.log.err("HTTP response body is empty. Request url: {s}", .{fetch_url});
                    return error.EmptyBody;
                }

                feed_options = FeedOptions.fromResponse(resp_2);
                if (feed_options.content_type == .html) {
                    // Let's make sure it is html, some give wrong content-type.
                    feed_options.content_type = parse.getContentType(feed_options.body) orelse .html;
                    const ct = feed_options.content_type;
                    if (ct == null or ct == .html) {
                        std.log.err("Got unexpected content type 'html' from response. Expected 'atom' or 'rss'.", .{});
                        return error.UnexpectedContentTypeHtml;
                    }
                }
                feed_options.feed_url = try req.get_url(arena.allocator());
                feed_options.title = link.title;
                return try self.storage.addFeed(&arena, feed_options);
            } else {
                feed_options.feed_url = try req.get_url(arena.allocator());
                return try self.storage.addFeed(&arena, feed_options);
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

        pub fn server() !void {
            print("Start server\n", .{});
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
