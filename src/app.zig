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
const ServerOptions = feed_types.ServerOptions;
const FetchOptions = feed_types.FetchHeaderOptions;
const fs = std.fs;
const http_client = @import("./http_client.zig");
const html = @import("./html.zig");
const AddRule = @import("add_rule.zig");

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
    rule: feed_types.RuleOptions,
    run: void,
    server: ServerOptions,
    tag: TagOptions,
    add: feed_types.AddOptions,
    batch: feed_types.BatchOptions,
};

const CliGlobal = struct {
    database: ?[:0]const u8 = null,
    help: bool = false,

    pub const shorthands = .{
        .h = "help",
        .d = "database",
    };
};

pub fn Cli(comptime Writer: type, comptime Reader: type) type {
    return struct {
        allocator: Allocator,
        storage: Storage = undefined,
        out: Writer,
        in: Reader,
        progress: std.Progress.Node,
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
                    _ = try self.update(input, opts);
                },
                .run => {
                    std.log.info("Running in foreground", .{});
                    const loop_limit = 5;
                    var loop_count: u16 = 0;
                    while (loop_count < loop_limit) {
                        if (try self.storage.next_update_countdown()) |countdown| {
                            if (countdown > 0) {
                                const countdown_ts = std.time.timestamp() + countdown;
                                const Datetime = @import("zig-datetime").datetime.Datetime;
                                var date = Datetime.fromSeconds(@floatFromInt(countdown_ts));
                                date = date.shiftTimezone(&@import("zig-datetime").timezones.Etc.GMTm3);

                                std.log.info("Next update in {d} second(s) [{d:0>2}.{d:0>2}.{d:0>4} {d:0>2}:{d:0>2}]", .{
                                    countdown,
                                    date.date.day,
                                    date.date.month,
                                    date.date.year,
                                    date.time.hour,
                                    date.time.minute,
                                });

                                loop_count = 0;
                                std.time.sleep(@intCast(countdown * std.time.ns_per_s));
                                continue;
                            }
                        }
                        if (try self.update(null, .{})) {
                            loop_count = 0;
                        } else {
                            loop_count += 1;
                        }
                    }
                    if (loop_count >= loop_limit) {
                        std.log.info("Stopped running foreground task. 'loop_count' exceeded 'loop_limit' - there is some logic mistake somewhere.", .{});
                    }
                },
                .tag => |opts| try self.tag(args.positionals, opts),
                .add => |opts| {
                    if (args.positionals.len == 0) {
                        try self.out.print("Please enter valid input you want to add or modify.\n", .{});
                        return;
                    }

                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    
                    var tags_ids: []usize = &.{};

                    if (opts.tags) |tags_raw| {
                        var tags_iter = mem.splitScalar(u8, tags_raw, ',');
                        const cap = mem.count(u8, tags_raw, ",") + 1;
                        var tags_arr = try std.ArrayList([]const u8).initCapacity(arena.allocator(), cap);
                        defer tags_arr.deinit();
                        while (tags_iter.next()) |tag_name| {
                            const trimmed = mem.trim(u8, tag_name, &std.ascii.whitespace);
                            if (trimmed.len > 0) {
                                tags_arr.appendAssumeCapacity(trimmed);
                            }
                        }

                        // make sure all tags exist in db/stroage
                        try self.storage.tags_add(tags_arr.items);

                        // get tags' ids
                        const tags_ids_buf = try arena.allocator().alloc(usize, tags_arr.items.len);
                        tags_ids = try self.storage.tags_ids(tags_arr.items, tags_ids_buf);
                    }

                    for (args.positionals) |input| {
                        const feed_id = self.add(input) catch |err| switch (err) {
                            error.InvalidUrl => {
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
                .server => |opts| try self.server(opts),
                .rule => |opts| try self.rule(opts),
                .batch => |opts| {
                    if (opts.@"check-all-icons") {
                        try self.check_icons(.all);
                    } else if (opts.@"check-missing-icons") {
                        try self.check_icons(.missing);
                    }
                }
            }
        }

        const IconCheckType = enum {
            all,
            missing,
        };

        fn check_icons(self: *Self, check_type: IconCheckType) !void {
            var buf: [1024]u8 = undefined;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var map = std.StringArrayHashMap([]const u8).init(arena.allocator());
            defer map.deinit();
            const feeds = switch (check_type) {
                .all => try self.storage.feed_icons_all(arena.allocator()),
                .missing => try self.storage.feed_icons_missing(arena.allocator()),
            };

            if (feeds.len == 0) {
                std.log.info("No feed icons to check", .{});
                return;
            }

            var count_updated: u32 = 0;
            const progress_node = self.progress.start("Checking icons", feeds.len);
            defer {
                progress_node.end();
                std.log.info("Icons checked: [{}/{}]", .{count_updated, feeds.len});
            }

            for (feeds) |feed| {
                const uri = std.Uri.parse(mem.trim(u8, feed.page_url, &std.ascii.whitespace)) catch |err| {
                    std.log.warn("Failed to parse feed page url '{s}'. Error: {}", .{feed.page_url, err});
                    continue;
                };
                const icon_path = "/favicon.ico";
                const url_request = try std.fmt.bufPrint(&buf, "{;+}{s}", .{uri, icon_path});
                const url_root = url_request[0..url_request.len - icon_path.len];
                if (map.get(url_request)) |value| {
                    try self.storage.feed_icon_update(feed.feed_id, value);
                    progress_node.completeOne();
                    count_updated += 1;
                    continue;
                }

                var req = try http_client.init(arena.allocator());
                defer req.deinit();

                // Check domain's '/favicon.ico' path
                if (try req.check_icon_path(url_request)) {
                    const key = try arena.allocator().dupe(u8, url_root);
                    const value = try arena.allocator().dupe(u8, url_request);
                    try map.put(key, value);
                    try self.storage.feed_icon_update(feed.feed_id, value);
                    progress_node.completeOne();
                    count_updated += 1;
                    continue;
                }

                var resp = req.fetch(url_root, .{}) catch |err| {
                    std.log.err("Failed to fetch '{s}'", .{url_root});
                    return err;
                };
                defer resp.deinit();

                if (resp.status_code == 200) {
                    const body = resp.body orelse {
                        std.log.warn("There is no body for '{s}'", .{url_root});
                        continue;
                    };
                    // TODO: replace this with function that only parses favicon
                    const html_parsed = try html.parse_html(arena.allocator(), body.items);
                    const icon_url = html_parsed.icon_url orelse continue;

                    const url_or_data = blk: {
                        if (mem.startsWith(u8, icon_url, "data:")) {
                            break :blk icon_url;
                        }

                        break :blk try feed_types.url_create(arena.allocator(), icon_url, uri);
                    };

                    const key = try arena.allocator().dupe(u8, url_root);
                    const value = try arena.allocator().dupe(u8, url_or_data);
                    try map.put(key, value);
                    try self.storage.feed_icon_update(feed.feed_id, value);
                    progress_node.completeOne();
                    count_updated += 1;
                } else {
                    std.log.warn("Failed to get favicon from '{s}'. Status code: {d}", .{url_root, resp.status_code});
                    continue;
                }
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
                \\  rule      Feed adding rules
                \\  run       Run update in foreground
                \\  show      Print feeds' items
                \\  server    Start server
                \\  batch     Do path actions
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
                    \\  -p, --port    Server port (default: 1222)
                    \\  -h, --help    Print this help and exit
                    ,
                    .tag => 
                    \\Usage: feedgaze tag [options]
                    \\
                    \\  Add/Remove tags. Or add/remove tags from feeds.
                    \\
                    \\Options:
                    \\  --feed        Add/Remove tags from feed base on this flags input
                    \\  --add         Add tags
                    \\  --remove      Remove tags
                    \\  --list        List tags
                    \\  -h, --help    Print this help and exit
                    ,
                    .add => 
                    \\Usage: feedgaze add [options] <input>
                    \\
                    \\  Add feed(s)
                    \\
                    \\Options:
                    \\  -h, --help    Print this help and exit
                    ,
                    .rule => 
                    \\Usage: feedgaze add [options] <input>
                    \\
                    \\  Feed adding rules
                    \\
                    \\Options:
                    \\  --list        List rules
                    \\  -h, --help    Print this help and exit
                    ,
                    .batch => 
                    \\Usage: feedgaze batch <options> [options]
                    \\
                    \\  Run batch actions
                    \\
                    \\Options:
                    \\  --check-all-icons        Check if all icons are valid
                    \\  --check-missing-icons    Fetch missing icons
                    \\  -h, --help               Print this help and exit
                    ,
                };
            }

            _ = try self.out.write(output);
        }

        pub fn rule(self: *Self, opts: feed_types.RuleOptions) !void {
            if (!opts.list) {
                try self.printHelp(.{.rule = opts});
            }

            if (opts.list) {
                const rules = try self.storage.rules_all(self.allocator);
                defer self.allocator.free(rules);
                if (rules.len == 0) {
                    try self.out.writeAll("There are no feed add rules.");
                    return;
                }
                var match_longest: u64 = 0;
                for (rules) |r| {
                    match_longest = @max(match_longest, r.match_url.len);
                }
                const first_column_width = match_longest + 4;

                { // 'Table' header
                    const first_column_name = "Rule to match"; 
                    try self.out.writeAll(first_column_name);
                    const space_count = first_column_width - first_column_name.len;
                    for (0..space_count) |_| {
                        try self.out.writeAll(" ");
                    }
                    try self.out.writeAll("Transform rule match to\n");
                }
                
                for (rules) |r| {
                    try self.out.print("{s}", .{r.match_url});
                    const space_count = first_column_width - r.match_url.len;
                    for (0..space_count) |_| {
                        try self.out.writeAll(" ");
                    }
                    try self.out.print("{s}\n", .{r.result_url});
                }
                return;
            }
        }
        
        const UserOutput = enum {
            yes,
            no,
            invalid,
        };
        fn user_output_state(str: []const u8) UserOutput {
            const trimmed = mem.trim(u8, str, &std.ascii.whitespace);
            if (trimmed.len != 1) {
                return .invalid;
            }
            const lower = std.ascii.toLower(trimmed[0]);
            if (lower == 'y') {
                return .yes;
            } else if (lower == 'n') {
                return .no;
            }
            return .invalid;
        }
        
        pub fn tag(self: *Self, inputs: [][]const u8, opts: TagOptions) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            if (!opts.list and !opts.remove and !opts.add) {
                try self.out.writeAll("Use on of these flags:\n");
                try self.out.writeAll("--list\n--add\n--remove\n\n");
                try self.printHelp(.{.tag = opts});
                return;
            }

            if (opts.list) {
                const tags = try self.storage.tags_all(arena.allocator());

                if (tags.len == 0) {
                    try self.out.print("There are no tags.\n", .{});
                }

                for (tags) |name| {
                    try self.out.print("- {s}\n", .{name});
                }
                return;
            }

            const flag_str, const flag_upper_str = blk: {
                if (opts.add) {
                    break :blk .{"add", "Add"};
                } else if (opts.remove) {
                    break :blk .{"remove", "Remove"};
                }
                unreachable;
            };

            if (inputs.len == 0) {
                try self.out.print("Enter tags you want to {s}: feegaze <flags> tag1 tag2\n", .{flag_str});
                return;
            }

            var tags_arr = try std.ArrayList([]const u8).initCapacity(arena.allocator(), inputs.len);
            defer tags_arr.deinit();
            for (inputs) |name| {
                const trimmed = mem.trim(u8, name, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    tags_arr.appendAssumeCapacity(trimmed);
                }
            }

            const feed_filter = mem.trim(u8, opts.feed orelse "", &std.ascii.whitespace);
            if (feed_filter.len == 0) {
                if (opts.add) {
                    try self.storage.tags_add(tags_arr.items);
                } else if (opts.remove) {
                    try self.storage.tags_remove(tags_arr.items);
                }
                return;
            }

            const feeds = try self.storage.feeds_search_complex(arena.allocator(), .{ .search = feed_filter });
            if (feeds.len == 0) {
                try self.out.print("Found no feeds to {s} tags to.\n", .{flag_str});
                return;
            }

            try self.out.print("{s} tags from feeds:\n", .{flag_upper_str});

            for (feeds) |feed| {
                try self.out.print("{s} | {s}\n", .{feed.title, feed.page_url orelse feed.feed_url});
            }

            var buf: [16]u8 = undefined;
            var fix_buf = std.io.fixedBufferStream(&buf);
            const invalid_msg = "Enter valid input 'y' or 'n'.\n";
            while (true) {
                try self.out.print("{s} tags to {d} feeds? ", .{flag_upper_str, feeds.len});
                fix_buf.reset();
                self.in
                    .streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len) catch |err| switch (err) {
                        error.StreamTooLong => {
                            try self.out.writeAll(invalid_msg);
                            continue;
                        },
                        else => return err,
                    };

                switch (user_output_state(fix_buf.getWritten())) {
                    .yes => {},
                    .no => {
                        return;
                    },
                    .invalid => {
                        try self.out.writeAll(invalid_msg);
                        continue;
                    },
                }
                break;
            }

            if (opts.remove) {
                for (feeds) |feed| {
                    try self.storage.tags_feed_remove(feed.feed_id, tags_arr.items);
                }
                try self.out.writeAll("Removed tags from feed(s).\n");
            } else if (opts.add) {
                try self.storage.tags_add(tags_arr.items);
                const tags_ids_buf = try arena.allocator().alloc(usize, tags_arr.items.len);
                const tags_ids = try self.storage.tags_ids(tags_arr.items, tags_ids_buf);

                for (feeds) |feed| {
                    try self.storage.tags_feed_add(feed.feed_id, tags_ids);
                }
                try self.out.print("Added tags to {d} feed(s).\n", .{feeds.len});
            }
        }

        pub fn add(self: *Self, url_raw: []const u8) !usize {
            const url = mem.trim(u8, url_raw, &std.ascii.whitespace);
            if (try self.storage.hasFeedWithFeedUrl(url)) {
                return error.FeedExists;
            }

            var app: App = .{ .storage = self.storage, .allocator = self.allocator };

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var fetch = try app.fetch_response(arena.allocator(), url);
            defer fetch.deinit();

            const resp = fetch.resp;

            var feed_options = FeedOptions.fromResponse(resp);
            if (feed_options.content_type == .html) {
                feed_options.content_type = parse.getContentType(feed_options.body) orelse .html;
            }

            var add_opts: Storage.AddOptions = .{ .feed_opts = feed_options };
            if (feed_options.content_type == .html) {
                const html_parsed = try html.parse_html(arena.allocator(), feed_options.body);
                const links = html_parsed.links;

                switch (try getUserInput(arena.allocator(), links, self.out, self.in)) {
                    .html => |html_opts| {
                        add_opts.feed_opts.feed_url = try fetch.req.get_url_slice();
                        add_opts.html_opts = html_opts;
                        add_opts.feed_opts.icon_url = html_parsed.icon_url;
                    },
                    .index => |index| {
                        const link = links[index];
                        var fetch_url = url;

                        if (!mem.startsWith(u8, link.link, "http")) {
                            var url_uri = try std.Uri.parse(url);
                            var link_buf = try arena.allocator().alloc(u8, url.len + link.link.len + 1);
                            const result = try url_uri.resolve_inplace(link.link, &link_buf);
                            fetch_url = try std.fmt.allocPrint(arena.allocator(), "{}", .{result});
                        } else {
                            fetch_url = link.link;
                        }

                        // Need to create new curl request
                        var fetch_2 = try app.fetch_response(arena.allocator(), fetch_url);
                        defer fetch_2.deinit();

                        const req_2 = fetch_2.req;
                        const resp_2 = fetch_2.resp;

                        add_opts.feed_opts = FeedOptions.fromResponse(resp_2);
                        if (feed_options.content_type == .html) {
                            // Let's make sure it is html, some give wrong content-type.
                            add_opts.feed_opts.content_type = parse.getContentType(feed_options.body) orelse .html;
                            const ct = feed_options.content_type;
                            if (ct == null or ct == .html) {
                                std.log.err("Got unexpected content type 'html' from response. Expected 'atom' or 'rss'.", .{});
                                return error.UnexpectedContentTypeHtml;
                            }
                        }
                        add_opts.feed_opts.feed_url = try req_2.get_url_slice();
                        add_opts.feed_opts.title = link.title;
                        add_opts.feed_opts.icon_url = html_parsed.icon_url;
                    }
                }
            } else {
                feed_options.feed_url = try fetch.req.get_url_slice();
            }

            // Add icon
            if (add_opts.feed_opts.icon_url == null) blk: {
                var buf: [1024]u8 = undefined;
                const uri = std.Uri.parse(mem.trim(u8, add_opts.feed_opts.feed_url, &std.ascii.whitespace)) catch |err| {
                    std.log.warn("Failed to parse feed page url '{s}'. Error: {}", .{add_opts.feed_opts.feed_url, err});
                    break :blk;
                };
                const icon_path = "/favicon.ico";
                const url_request = try std.fmt.bufPrint(&buf, "{;+}{s}", .{uri, icon_path});
                const url_root = url_request[0..url_request.len - icon_path.len];

                var req = try http_client.init(arena.allocator());
                defer req.deinit();

                // Check domain's '/favicon.ico' path
                if (try req.check_icon_path(url_request)) {
                    add_opts.feed_opts.icon_url = try arena.allocator().dupe(u8, url_request);
                    break :blk;
                }

                var resp_icon = req.fetch(url_root, .{}) catch |err| {
                    std.log.err("Failed to fetch '{s}'", .{url_root});
                    return err;
                };
                defer resp_icon.deinit();

                if (resp_icon.status_code == 200) {
                    const body = resp_icon.body orelse {
                        std.log.warn("There is no body for '{s}'", .{url_root});
                        break :blk;
                    };
                    // TODO: replace this with function that only parses favicon
                    const html_parsed = try html.parse_html(arena.allocator(), body.items);
                    const icon_url = html_parsed.icon_url orelse break :blk;

                    const url_or_data = icon: {
                        if (mem.startsWith(u8, icon_url, "data:")) {
                            break :icon icon_url;
                        }

                        break :icon try feed_types.url_create(arena.allocator(), icon_url, uri);
                    };

                    add_opts.feed_opts.icon_url = try arena.allocator().dupe(u8, url_or_data);
                } else {
                    std.log.warn("Failed to get favicon from '{s}'. Status code: {d}", .{url_root, resp_icon.status_code});
                    break :blk;
                }
            }

            const feed_id = try self.storage.addFeed(self.allocator, add_opts);
            return feed_id;
        }

        const UserInput = union(enum) {
            index: usize,
            html: parse.HtmlOptions,
        };
        fn getUserInput(allocator: Allocator, links: []html.FeedLink, writer: Writer, reader: Reader) !UserInput {
            if (links.len == 0) {
                try writer.print("Found no feed links in html\n", .{});
            } else {
                try writer.print("Pick feed link to add\n", .{});
            }
            for (links, 1..) |link, i| {
                try writer.print("{d}. {s} | {s}\n", .{i, link.title orelse "<no-title>", link.link});
            }
            const html_option_index = links.len + 1;
            try writer.print("{d}. Add html as feed\n", .{html_option_index});
            var buf: [32]u8 = undefined;
            var fix_buf = std.io.fixedBufferStream(&buf);
            var index: usize = 0;

            while (index == 0 or index > links.len) {
                fix_buf.reset();
                try writer.writeAll("Enter number: ");
                try reader.streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len);
                const value = mem.trim(u8, fix_buf.getWritten(), &std.ascii.whitespace);
                index = std.fmt.parseUnsigned(usize, std.mem.trim(u8, value, &std.ascii.whitespace), 10) catch {
                    try writer.print("Provided input is not a number. Enter number between 1 - {d}\n", .{links.len + 1});
                    continue;
                };
                if (index == html_option_index) {
                    return .{ .html = try html_options(allocator, writer, reader) };
                } else if (index == 0 or index > links.len) {
                    try writer.print("Invalid number input. Enter number between 1 - {d}\n", .{links.len + 1});
                    continue;
                }
            }
            return .{ .index = index - 1 };
        }

        fn html_options(allocator: Allocator, writer: Writer, reader: Reader) !parse.HtmlOptions {
            var opts: parse.HtmlOptions = .{ .selector_container = undefined };
            var buf: [1024]u8 = undefined;
            var fix_buf = std.io.fixedBufferStream(&buf);

            try writer.writeAll("Can enter simple selector that are made up of tag names or classes. Like: '.item div'\n");

            while (true) {
                try writer.writeAll("Enter feed item's selector: ");
                fix_buf.reset();
                try reader.streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len);
                if (get_input_value(fix_buf.getWritten())) |val| {
                    opts.selector_container = try allocator.dupe(u8, val);
                    break;
                }
            }

            try writer.writeAll("Rest of the selector options view feed item selector as root.\n");
            try writer.writeAll("Enter feed item's link selector: ");
            fix_buf.reset();
            try reader.streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len);
            if (get_input_value(fix_buf.getWritten())) |val| {
                opts.selector_link = try allocator.dupe(u8, val);
            }

            try writer.writeAll("Enter feed item's title selector: ");
            fix_buf.reset();
            try reader.streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len);
            if (get_input_value(fix_buf.getWritten())) |val| {
                opts.selector_heading = try allocator.dupe(u8, val);
            }

            try writer.writeAll("Enter feed item's date selector: ");
            fix_buf.reset();
            try reader.streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len);
            if (get_input_value(fix_buf.getWritten())) |val| {
                opts.selector_date = try allocator.dupe(u8, val);
            }

            try writer.writeAll(
            \\Can set date format that will be parsed from date selector's content.
            \\If date content has other characters, can fill them in with anything.
            \\Important is the position of date options.
            \\Format options:
            \\- year: YY, YYYY
            \\- month: MM, MMM (Jan, Sep)
            \\- day: DD
            \\- hour: HH
            \\- minute: mm
            \\- second: ss
            \\- timezone: Z (+02:00, -0800)
            \\
            );
            try writer.writeAll("Enter feed date format: ");
            fix_buf.reset();
            try reader.streamUntilDelimiter(fix_buf.writer(), '\n', fix_buf.buffer.len);
            if (get_input_value(fix_buf.getWritten())) |val| {
                opts.date_format = try allocator.dupe(u8, val);
            }

            return opts;
        }

        fn get_input_value(input: []const u8) ?[]const u8 {
            const value = mem.trim(u8, input, &std.ascii.whitespace);
            if (value.len == 0) {
                return null;
            }

            return value;
        }

        pub fn update(self: *Self, input: ?[]const u8, options: UpdateOptions) !bool {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const feed_updates = try self.storage.getFeedsToUpdate(arena.allocator(), input, options);
            if (feed_updates.len == 0) {
                std.log.info("No feeds to update", .{});
                return false;
            }

            var item_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer item_arena.deinit();

            var count_updated: u32 = 0;
            const progress_node = self.progress.start("Updating feeds", feed_updates.len);
            defer {
                progress_node.end();
                std.log.info("Feeds updated: [{}/{}]", .{count_updated, feed_updates.len});
            }

            for (feed_updates) |f_update| {
                errdefer |err| {
                    std.log.err("Update loop error: {}", .{err});
                    self.storage.rate_limit_remove(f_update.feed_id) catch {
                        @panic("Failed to remove feed from rate limit");
                    };
                    self.storage.add_to_last_update(f_update.feed_id, std.time.s_per_hour * 12) catch {
                        @panic("Failed to update (increase) feed's next update");
                    };
                }
                _ = item_arena.reset(.retain_capacity);
                var req = http_client.init(item_arena.allocator()) catch |err| {
                    try self.storage.add_to_last_update(f_update.feed_id, std.time.s_per_min * 20);
                    std.log.err("Failed to start http request to '{s}'. Error: {}", .{f_update.feed_url, err});
                    continue;
                }; 
                defer req.deinit();
                
                const resp = req.fetch(f_update.feed_url, .{
                    .etag = f_update.etag,
                    .last_modified_utc = f_update.last_modified_utc,
                }) catch |err| {
                    try self.storage.add_to_last_update(f_update.feed_id, std.time.s_per_min * 20);
                    std.log.err("Failed to fetch feed '{s}'. Error: {}", .{f_update.feed_url, err});
                    continue;
                };
                defer resp.deinit();

                if (resp.status_code == 304) {
                    // Resource hasn't been modified
                    try self.storage.updateLastUpdate(f_update.feed_id);
                    try self.storage.rate_limit_remove(f_update.feed_id);
                    progress_node.completeOne();
                    count_updated += 1;
                    continue;
                } else if (resp.status_code == 503) {
                    const retry_ts = std.time.timestamp() + std.time.s_per_hour;
                    try self.storage.rate_limit_add(f_update.feed_id, retry_ts);
                    continue;
                } else if (resp.status_code == 429) {
                    std.log.warn("Rate limit hit with feed '{s}'", .{f_update.feed_url});
                    const now_utc_sec = std.time.timestamp();
                    const retry_reset = blk: {
                        if (try resp.getHeader("x-ratelimit-remaining")) |remaining| {
                            const raw = remaining.get();
                            std.debug.assert(raw.len > 0);
                            const value = try std.fmt.parseFloat(f32, raw);
                            if (value == 0.0) {
                                if (try resp.getHeader("x-ratelimit-reset")) |header| {
                                    if (std.fmt.parseUnsigned(i64, header.get(), 10)) |nr| {
                                        std.log.debug("x-ratelimit-reset", .{});
                                        break :blk now_utc_sec + nr + 1;
                                    } else |_| {}
                                }
                            }
                        }

                        if (try resp.getHeader("retry-after") orelse 
                            try resp.getHeader("x-ratelimit-reset")) |header| {
                                const raw = header.get();
                                std.log.debug("header rate-limit: {s}", .{raw});
                                if (std.fmt.parseUnsigned(i64, raw, 10)) |nr| {
                                    break :blk now_utc_sec + nr + 1;
                                } else |_| {}

                                if (feed_types.RssDateTime.parse(raw)) |date_utc| {
                                    break :blk date_utc + 1;
                                } else |_| {}
                        }
                        break :blk now_utc_sec + std.time.s_per_hour;
                    };
                    print("retry_reset: {d}\n", .{retry_reset});
                    try self.storage.rate_limit_add(f_update.feed_id, retry_reset);
                    continue;
                } else if (resp.status_code >= 400 and resp.status_code < 600) {
                    try self.storage.rate_limit_remove(f_update.feed_id);
                    try self.storage.add_to_last_update(f_update.feed_id, std.time.s_per_hour * 12);
                    std.log.err("Request to '{s}' failed with status code {d}", .{f_update.feed_url, resp.status_code});
                    continue;
                }

                self.storage.updateFeedAndItems(&item_arena, resp, f_update) catch |err| {
                    try self.storage.rate_limit_remove(f_update.feed_id);
                    try self.storage.add_to_last_update(f_update.feed_id, std.time.s_per_hour * 12);
                    std.log.err("Failed to update feed '{s}'. Error: {}", .{f_update.feed_url, err});
                    continue;
                };
                progress_node.completeOne();
                count_updated += 1;
            }
            return true;
        }

        pub fn server(self: *Self, opts: ServerOptions) !void {
            try @import("server.zig").start_server(self.storage, opts);
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
    var buf: [8 * 1024]u8 = undefined;
    var fixed_alloc = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fixed_alloc.allocator();

    const db_path = blk: {
        const db_path = path orelse db_path: {
            const kf = @import("known-folders");
            const data_dir = try kf.getPath(alloc, .data) orelse unreachable;
            const file_path = try std.fs.path.joinZ(alloc, &.{data_dir, "feedgaze",  "feedgaze.sqlite"});

            break :db_path file_path;
        };
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
            var path_buf: [fs.max_path_bytes]u8 = undefined;
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

pub const App = struct {
    storage: Storage, 
    allocator: Allocator,

    const curl = @import("curl");
    const RequestResponse = struct {
        req: http_client,
        resp: curl.Easy.Response,

        pub fn deinit(self: *@This()) void {
            self.resp.deinit();
            self.req.deinit();
        }
    };

    pub fn fetch_response(self: *@This(), allocator: std.mem.Allocator, input_url: []const u8) !RequestResponse {
        const uri = std.Uri.parse(input_url) catch {
            return error.InvalidUrl;
        };

        var fetch_url = input_url;

        if (uri.host) |host| {
            const host_str = AddRule.uri_component_val(host);
            const rules = try self.storage.get_rules_for_host(allocator, host_str);
            defer allocator.free(rules);
            if (try AddRule.find_rule_match(uri, rules)) |rule| {
                std.log.info("Found matching rule. Using rule to transform url.", .{});
                fetch_url = try AddRule.transform_rule_match(allocator, uri, rule);
            }
        }

        // fetch url content
        var req = try http_client.init(allocator);
        const resp = try req.fetch(fetch_url, .{});

        if (resp.body.?.items.len == 0) {
            std.log.err("HTTP response body is empty. Request url: {s}", .{fetch_url});
            return error.EmptyBody;
        }

        return .{
            .req = req,
            .resp = resp,
        };
    }

};
