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
const is_url = @import("util.zig").is_url; 

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
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const inputs = try fix_args_type(arena.allocator(), args.positionals);
                    try self.show(inputs, opts);
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
                        if (try self.storage.next_update_timestamp()) |timestamp_next| {
                            const now_ts = std.time.timestamp();
                            if (timestamp_next > now_ts) {
                                const Datetime = @import("zig-datetime").datetime.Datetime;
                                var date = Datetime.fromSeconds(@floatFromInt(timestamp_next));
                                date = date.shiftTimezone(&@import("zig-datetime").timezones.Europe.Helsinki);

                                var buf: [32]u8 = undefined;
                                const countdown_ts = timestamp_next - now_ts;
                                std.log.info("Next update in {s} [{d:0>2}.{d:0>2}.{d:0>4} {d:0>2}:{d:0>2}]", .{
                                    try relative_time_from_seconds(&buf, countdown_ts),
                                    date.date.day,
                                    date.date.month,
                                    date.date.year,
                                    date.time.hour,
                                    date.time.minute,
                                });

                                loop_count = 0;
                                std.time.sleep(@intCast(countdown_ts * std.time.ns_per_s));
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
                .tag => |opts| {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const inputs = try fix_args_type(arena.allocator(), args.positionals);
                    try self.tag(inputs, opts);
                },
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
                .rule => |opts| {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const inputs = try fix_args_type(arena.allocator(), args.positionals);
                    try self.rule(inputs, opts);
                },
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
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const progress_node = self.progress.start("Checking icons", 0);
            defer { progress_node.end(); }

            var total: usize = 0;
            if (check_type == .all) {
                const icons_existing = try self.storage.feed_icons_existing(arena.allocator());
                total += icons_existing.len;
                progress_node.setEstimatedTotalItems(total);
                for (icons_existing) |icon| {
                    var req = try http_client.init(arena.allocator());
                    defer {
                        progress_node.completeOne();
                        req.deinit();
                    }

                    if (!mem.startsWith(u8, icon.icon_url, "data:")) blk: {
                        const resp_image, const resp_body = req.fetch_image(icon.icon_url) catch {
                            try self.storage.icon_failed_add(icon.feed_id);
                            break :blk;
                        };
                        defer resp_image.deinit();

                        const resp_url = req.get_url_slice() catch |err| {
                            std.log.warn("Failed to get requests effective url that was started by '{s}'. Error: {}", .{icon.icon_url, err});
                            break :blk;
                        };

                        try self.storage.icon_update(icon.icon_url, .{
                            .url = resp_url,
                            .data = resp_body,
                        });
                        continue;
                    }

                    const icon_opt = App.fetch_icon(arena.allocator(), icon.page_url, null) catch {
                        try self.storage.icon_failed_add(icon.feed_id);
                        continue;
                    };

                    if (icon_opt) |icon_obj| {
                        try self.storage.icon_update(icon.icon_url, icon_obj);
                    } else {
                        try self.storage.icon_failed_add(icon.feed_id);
                    }
                }
            }

            const icons_missing = try self.storage.feed_icons_missing(arena.allocator());
            total += icons_missing.len;

            if (total == 0) {
                std.log.info("No feed icons to check", .{});
                return;
            }

            progress_node.setEstimatedTotalItems(total);

            for (icons_missing) |icon| {
                defer {
                    progress_node.completeOne();
                }

                const new_icon_opt = App.fetch_icon(arena.allocator(), icon.page_url, null) catch {
                    try self.storage.icon_failed_add(icon.feed_id);
                    continue;
                };

                if (new_icon_opt) |new_icon| {
                    const icon_id_opt = try self.storage.icon_upsert(new_icon);
                    if (icon_id_opt) |icon_id| {
                        try self.storage.feed_icon_update(icon.feed_id, icon_id);
                    }
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
                \\
                \\General options:
                \\
                \\  -h, --help        Print command-specific usage
                \\  -d, --database    Database location 
                \\
                \\
            ;

            if (verb) |v| {
                output = switch (v) {
                    .remove =>
                    \\Usage: feedgaze remove <search_term> [options]
                    \\
                    \\  Remove feed. Search term will match page or feed url. 
                    \\
                    \\Options:
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    \\
                    ,
                    .show =>
                    \\Usage: feedgaze show [search_term] [options]
                    \\
                    \\  Show feed(s). Optional search term. Search term will match page or feed url. Most recently updated feeds will be shown first.
                    \\
                    \\Options:
                    \\  -l, --limit     Limit how many feeds to show
                    \\  --item-limit    Limit how many feed items to show
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    \\
                    ,
                    .update =>
                    \\Usage: feedgaze update [search_term] [options]
                    \\
                    \\  Update feed(s). Search term will match page or feed url. 
                    \\
                    \\Options:
                    \\  --force         Will force update all matched feeds
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    ,
                    .run =>
                    \\Usage: feedgaze run [options]
                    \\
                    \\  Auto update feeds in the foreground. 
                    \\
                    \\Options:
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    ,
                    .server => 
                    \\Usage: feedgaze server [options]
                    \\
                    \\  Launches server
                    \\
                    \\Options:
                    \\  -p, --port      Server port (default: 1222)
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    ,
                    .tag => 
                    \\Usage: feedgaze tag [options]
                    \\
                    \\  Add/Remove tags. Or add/remove tags from feeds.
                    \\
                    \\Options:
                    \\  --feed          Add/Remove tags from feed base on this flags input
                    \\  --add           Add tags
                    \\  --remove        Remove tags
                    \\  --list          List tags
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    ,
                    .add => 
                    \\Usage: feedgaze add [options] <input>
                    \\
                    \\  Add feed(s)
                    \\
                    \\Options:
                    \\  --tags          Tags to add. Comma separated
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    ,
                    .rule => 
                    \\Usage: feedgaze rule [options] [match-url] [result-url]
                    \\
                    \\  Feed adding rules. 
                    \\  Example: 'domain.com/*/*' -> 'domain.com/*/*.atom'
                    \\
                    \\Options:
                    \\  --list          List rules
                    \\  --add           Add new rule
                    \\  -d, --database  Database location 
                    \\  -h, --help      Print this help and exit
                    ,
                    .batch => 
                    \\Usage: feedgaze batch <options> [options]
                    \\
                    \\  Run batch actions
                    \\
                    \\Options:
                    \\  --check-all-icons        Check if all icons are valid
                    \\  --check-missing-icons    Fetch missing icons
                    \\  -d, --database           Database location 
                    \\  -h, --help               Print this help and exit
                    ,
                };
            }

            _ = try self.out.write(output);
        }

        pub fn rule(self: *Self, inputs: [][]const u8, opts: feed_types.RuleOptions) !void {
            if (!opts.list and !opts.add and !opts.remove) {
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
            } else if (opts.add) {
                if (inputs.len < 2) {
                    try self.out.writeAll("'--add' requires to inputs: <match-url> <result-url>\n");
                    return;
                }
                const match_str = mem.trim(u8, inputs[0], &std.ascii.whitespace);
                const result_str = mem.trim(u8, inputs[1], &std.ascii.whitespace);
                if (match_str.len == 0) {
                    try self.out.writeAll("'--add' input <match-url> <result-url>\n");
                }
                const rule_new = AddRule.create_rule(match_str, result_str) catch |err| switch (err) {
                    error.InvalidMatchUrl => {
                        try self.out.writeAll("Enter valid <match-url>");
                        return;
                    },
                    error.MissingMatchHost => {
                        try self.out.writeAll("Add host domain to <match-url>");
                        return;
                    },
                    error.InvalidResultUrl => {
                        try self.out.writeAll("Enter valid <result-url>");
                        return;
                    },
                };
                if (try self.storage.has_rule(rule_new)) {
                    try self.out.writeAll("Rule already exists\n");
                    return;
                }
                try self.storage.rule_add(rule_new);
            } else if (opts.remove) {
                if (inputs.len == 0) {
                    try self.out.writeAll("'--remove' requires input to filter rules.\n");
                    return;
                }
                const rules = try self.storage.rules_filter(self.allocator, inputs[0]);
                const invalid_msg = "Enter valid input 'y' or 'n'.\n";
                var buf: [16]u8 = undefined;
                var fix_buf = std.io.fixedBufferStream(&buf);

                for (rules) |r| {
                    while (true) {
                        try self.out.print("Remove rule '{s}' -> '{s}'? (y/n) ", .{r.match_url, r.result_url});
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
                            .yes => {
                                try self.storage.rule_remove(r.add_rule_id);
                                break;
                            },
                            .no => {
                                break;
                            },
                            .invalid => {
                                try self.out.writeAll(invalid_msg);
                                continue;
                            },
                        }
                    }
                }
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
                try self.out.print("{s} tags to {d} feeds? (y/n) ", .{flag_upper_str, feeds.len});
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

            var app: App = .{ .storage = self.storage };

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var fetch_2: ?App.RequestResponse = null;
            defer if (fetch_2) |*f| f.deinit();

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

                if (html_parsed.icon_url) |icon_url| {
                    add_opts.feed_opts.icon = feed_types.Icon.init_if_data(try fetch.req.get_url_slice(), icon_url);
                }

                switch (try getUserInput(arena.allocator(), links, self.out, self.in)) {
                    .html => |html_opts| {
                        add_opts.feed_opts.feed_url = try fetch.req.get_url_slice();
                        add_opts.html_opts = html_opts;
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
                        fetch_2 = try app.fetch_response(arena.allocator(), fetch_url);

                        add_opts.feed_opts = FeedOptions.fromResponse(fetch_2.?.resp);
                        add_opts.feed_opts.feed_url = try fetch_2.?.req.get_url_slice();
                        add_opts.feed_opts.title = link.title;
                    }
                }

                if (add_opts.feed_opts.icon == null) {
                    // TODO: What if html_parsed.icon has can icon url (not 'data:...')?
                    add_opts.feed_opts.icon = App.fetch_icon(arena.allocator(), add_opts.feed_opts.feed_url, null) catch null;
                }
            } else {
                add_opts.feed_opts.feed_url = try fetch.req.get_url_slice();
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

            var app: App = .{ .storage = self.storage };

            for (feed_updates) |f_update| {
                _ = item_arena.reset(.retain_capacity);
                const r = try app.update_feed(&item_arena, f_update);
                switch (r) {
                    .added, .no_changes => {
                        progress_node.completeOne();
                        count_updated += 1;
                    },
                    .failed => {},
                }
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

    const UpdateResult = enum {
        added,
        no_changes,
        failed,
    };

    pub fn update_feed(self: *@This(), arena: *std.heap.ArenaAllocator, f_update: FeedToUpdate) !UpdateResult {
        errdefer |err| {
            std.log.err("Update loop error: {}", .{err});
            const retry_ts = std.time.timestamp() + (std.time.s_per_hour * 12);
            self.storage.rate_limit_add(f_update.feed_id, retry_ts) catch {
                @panic("Failed to update (increase) feed's next update");
            };
        }
        var req = http_client.init(arena.allocator()) catch |err| {
            const retry_ts = std.time.timestamp() + (std.time.s_per_min * 20);
            try self.storage.rate_limit_add(f_update.feed_id, retry_ts);
            std.log.err("Failed to start http request to '{s}'. Error: {}", .{f_update.feed_url, err});
            return .failed;
        }; 
        defer req.deinit();
        
        const resp = req.fetch(f_update.feed_url, .{
            .etag = f_update.etag,
            .last_modified_utc = f_update.last_modified_utc,
        }) catch |err| {
            const retry_ts = std.time.timestamp() + (std.time.s_per_hour * 8);
            try self.storage.rate_limit_add(f_update.feed_id, retry_ts);
            std.log.err("Failed to fetch feed '{s}'. Error: {}", .{f_update.feed_url, err});
            return .failed;
        };
        defer resp.deinit();

        if (resp.status_code == 304) {
            // Resource hasn't been modified
            try self.storage.updateLastUpdate(f_update.feed_id);
            try self.storage.rate_limit_remove(f_update.feed_id);
            return .no_changes;
        } else if (resp.status_code == 503) {
            const retry_ts = std.time.timestamp() + std.time.s_per_hour;
            try self.storage.rate_limit_add(f_update.feed_id, retry_ts);
            return .failed;
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
            return .failed;
        } else if (resp.status_code >= 400 and resp.status_code < 600) {
            const retry_ts = std.time.timestamp() + (std.time.s_per_hour * 12);
            try self.storage.rate_limit_add(f_update.feed_id, retry_ts);
            std.log.err("Request to '{s}' failed with status code {d}", .{f_update.feed_url, resp.status_code});
            return .failed;
        }

        self.storage.updateFeedAndItems(arena, resp, f_update) catch |err| {
            const retry_ts = std.time.timestamp() + (std.time.s_per_hour * 12);
            try self.storage.rate_limit_add(f_update.feed_id, retry_ts);
            std.log.err("Failed to update feed '{s}'. Error: {}", .{f_update.feed_url, err});
            return .failed;
        };

        return .added;
    }

    // if return null -> missing icons
    // if return error -> failed icons
    pub fn fetch_icon(allocator: Allocator, input_url: []const u8, icon_url_opt: ?[]const u8) !?feed_types.Icon {
        std.debug.assert(!mem.startsWith(u8, icon_url_opt orelse "", "data:"));

        var buf: [1024]u8 = undefined;
        const uri = try std.Uri.parse(mem.trim(u8, input_url, &std.ascii.whitespace));

        // Try to find icon from html
        const error_icon = failed: {
            var req = http_client.init(allocator) catch |err| break :failed err;
            defer { req.deinit(); }

            const req_url = std.fmt.bufPrint(&buf, "{;+}", .{uri}) catch |err| break :failed err;
            const resp = req.fetch(req_url, .{}) catch |err| break :failed err;
            defer resp.deinit();

            const body = http_client.response_200_and_has_body(resp, req_url) orelse "";

            if (html.parse_icon(body)) |icon_url| {
                if (mem.startsWith(u8, icon_url, "data:")) {
                    const url_final = req.get_url_slice() catch |err| break :failed err;
                    return .{
                        .url = allocator.dupe(u8, url_final) catch |err| break :failed err,
                        .data = allocator.dupe(u8, icon_url) catch |err| break :failed err,
                    };
                } else {
                    const req_icon_url = blk: {
                        if (icon_url[0] == '/' or icon_url[0] == '.') {
                            const url = std.mem.trimLeft(u8, icon_url, ".");
                            break :blk (std.fmt.bufPrint(&buf, "{;+}{s}", .{uri, url})
                                catch |err| break :failed err);
                        }
                        break :blk icon_url;
                    };

                    // Fetch icon body/content
                    const resp_image, const resp_body = req.fetch_image(req_icon_url)
                        catch |err| break :failed err;
                    defer resp_image.deinit();

                    const url_final = req.get_url_slice()
                        catch |err| break :failed err;
                    return .{
                        .url = allocator.dupe(u8, url_final) catch |err| break :failed err,
                        .data = allocator.dupe(u8, resp_body) catch |err| break :failed err,
                    };
                }
            }
            break :failed;
        };

        if (error_icon) {
            std.log.info("Did not find icon for '{s}'.", .{input_url});
        } else |err| {
            std.log.warn("Failed to fetch icon from html. Request url: '{s}'. Error: {}", .{input_url, err});
        }

        // Fallback icon. See if there is and icon in '/favicon.ico'
        {
            errdefer |err| {
                std.log.warn("Failed to fetch fallback icon '/favicon.ico' for '{s}'. Error: {}", .{input_url, err});
            }

            var req = try http_client.init(allocator);
            defer { req.deinit(); }

            const url_request = try std.fmt.bufPrint(&buf, "{;+}/favicon.ico", .{uri});
            const resp, const body = try req.fetch_image(url_request);
            defer resp.deinit();

            const url_favicon = try req.get_url_slice();
            return .{
                .url = try allocator.dupe(u8, url_favicon),
                .data = try allocator.dupe(u8, body),
            };
        }

        if (error_icon) {
            return null;
        } else |err| {
            return err;
        }
    }
};

fn relative_time_from_seconds(buf: []u8,  seconds: i64) ![]const u8 {
    if (seconds <= 0) {
        return try std.fmt.bufPrint(buf, "now", .{});
    }

    const day = @divFloor(seconds, std.time.s_per_day);
    const hour = @divFloor(seconds, std.time.s_per_hour);
    const minute = @divFloor(seconds, std.time.s_per_min);
    const second = seconds;

    const year = @divFloor(day, 365);
    const month = @divFloor(day, 365 / 12);

    if (year > 0) {
        const plural = if (year > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} year{s}", .{year, plural});
    } else if (month > 0) {
        const plural = if (month > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} month{s}", .{month, plural});
    } else if (day > 0) {
        const plural = if (day > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} day{s}", .{day, plural});
    } else if (hour > 0) {
        const plural = if (hour > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} hour{s}", .{hour, plural});
    } else if (minute > 0) {
        const plural = if (minute > 1) "s" else "";
        return try std.fmt.bufPrint(buf, "{d} minute{s}", .{minute, plural});
    }

    const plural = if (second > 1) "s" else "";
    return try std.fmt.bufPrint(buf, "{d} second{s}", .{second, plural});
}

fn fix_args_type(allocator: std.mem.Allocator, inputs: [][:0]const u8) ![][]const u8 {
    var arr = try std.ArrayList([]const u8).initCapacity(allocator, inputs.len);
    defer arr.deinit();
    for (inputs) |pos| {
        arr.appendAssumeCapacity(pos);
    }

    return arr.toOwnedSlice();
}
