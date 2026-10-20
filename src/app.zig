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
const FeedParser = @import("./feed_parse.zig");
const ValidFeed = FeedParser.ValidFeed;
const ContentType = FeedParser.ContentType;
const builtin = @import("builtin");
const args_parser = @import("zig-args");
const ShowOptions = feed_types.ShowOptions;
const UpdateOptions = feed_types.UpdateOptions;
const TagOptions = feed_types.TagOptions;
const ServeOptions = feed_types.ServeOptions;
const FetchOptions = feed_types.FetchHeaderOptions;
const fs = std.fs;
const http_client = @import("./http_client.zig");
const html = @import("./html.zig");
const AddRule = @import("add_rule.zig");
const util = @import("util.zig"); 
const is_url = util.is_url; 
const image = @import("image.zig");
const zdt = @import("zdt");
const config = @import("app_config.zig");

pub const Response = struct {
    feed_update: FeedUpdate,
    content: []const u8,
    content_type: ContentType,
    location: []const u8,
};

const IndexData = struct{index_item: usize, index_future: usize};
const QueueData = std.Io.Queue(IndexData);

const CliVerb = union(enum) {
    remove: void,
    show: ShowOptions,
    update: UpdateOptions,
    rule: feed_types.RuleOptions,
    run: void,
    serve: ServeOptions,
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

pub const Cli = struct {
    allocator: Allocator,
    storage: Storage = undefined,
    io: std.Io,
    out: *std.Io.Writer,
    in: *std.Io.Reader,
    core_count: usize,
    const Self = @This();

    pub fn run(self: *Self, process_init: std.process.Init) !void {
        var args = try args_parser.parseWithVerbForCurrentProcess(CliGlobal, CliVerb, process_init, .print);
        defer args.deinit();

        if (args.options.help) {
            try self.printHelp(args.verb);
            return;
        }

        const verb = args.verb orelse {
            return;
        };

        var buf_path: [8 * 1024]u8 = undefined;
        const db_path = try get_path_db(&buf_path, process_init, args.options.database);
        var storage_init_count: u32 = 0;
        const wait_time_sec = 5;
        while (storage_init_count < 3) : (storage_init_count += 1) {
            self.storage = Storage.init(db_path) catch |err| {
                if (err == @import("sqlite").Error.SQLITE_BUSY) {
                    std.log.info("Sqlite database seems busy. Trying again in {} seconds", .{wait_time_sec});
                    try self.io.sleep(.fromSeconds(wait_time_sec), .boot);
                    continue;
                }
                return err;
            };
            break;
        }

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
                try self.update(input, opts);
            },
            .run => {
                std.log.info("Running in foreground", .{});
                const loop_count_max = 5;
                var loop_count: u16 = 0;
                const tz_system_local = try zdt.Timezone.tzLocal(self.io, null);
                while (loop_count < loop_count_max) {
                    if (try self.storage.next_update_timestamp()) |timestamp_next| {
                        const now_ts = std.Io.Clock.real.now(self.io).toSeconds();
                        if (timestamp_next > now_ts) {
                            // const utc_offset = try zdt.UTCoffset.fromSeconds(2 * 60 * 60, "GMT+2", false);
                            const date = try zdt.Datetime.fromUnix(timestamp_next, .second, .{ .tz = &tz_system_local });

                            var buf: [32]u8 = undefined;
                            const countdown_ts = timestamp_next - now_ts;
                            std.log.info("Next update in {s} [{d:0>2}.{d:0>2}.{d:0>} {d:0>2}:{d:0>2}]", .{
                                try relative_time_from_seconds(&buf, countdown_ts),
                                date.day,
                                date.month,
                                @as(u32, @intCast(date.year)),
                                date.hour,
                                date.minute,
                            });

                            loop_count = 0;
                            try self.io.sleep(.fromSeconds(countdown_ts), .boot);
                            continue;
                        }
                    }

                    if (self.update(null, .{})) |_| {
                        loop_count = 0;
                    } else |err| {
                        if (err == error.NameServerFailure or err == error.NetworkUnreachable) {
                            const wait_sec = std.Io.Duration.fromSeconds(3 * loop_count + 1);
                            std.log.warn("Failed to update feeds because a network problem. Will try again in {d} seconds", .{wait_sec.toSeconds()});
                            try self.io.sleep(wait_sec, .boot);
                        }
                        loop_count += 1;
                    }
                } else {
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
                
                var tags_ids: []feed_types.SqliteId = &.{};

                if (opts.tags) |tags_raw| {
                    var tags_iter = mem.splitScalar(u8, tags_raw, ',');
                    const cap = mem.count(u8, tags_raw, ",") + 1;
                    var tags_arr = try std.ArrayList([]const u8).initCapacity(arena.allocator(), cap);
                    defer tags_arr.deinit(arena.allocator());
                    while (tags_iter.next()) |tag_name| {
                        const trimmed = mem.trim(u8, tag_name, &std.ascii.whitespace);
                        if (trimmed.len > 0) {
                            tags_arr.appendAssumeCapacity(trimmed);
                        }
                    }

                    // make sure all tags exist in db/stroage
                    try self.storage.tags_add(tags_arr.items);

                    // get tags' ids
                    const tags_ids_buf = try arena.allocator().alloc(feed_types.SqliteId, tags_arr.items.len);
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
            .serve => |opts| try self.serve(opts),
            .rule => |opts| {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const inputs = try fix_args_type(arena.allocator(), args.positionals);
                try self.rule(inputs, opts);
            },
            .batch => |opts| {
                if (opts.@"check-missing-icons") {
                    try self.check_icons(.missing);
                } else if (opts.@"check-failed-icons") {
                    try self.check_icons(.failed);
                }
            }
        }
    }

    const IconCheckType = enum {
        missing,
        failed,
    };

    const IconExistsUnion = union {
        const Return = union(enum) {
            success: struct {
                icon: feed_types.Icon,
                curr_icon_id: feed_types.IconRender.ID,
                arena_index: usize,
            },
            err: struct {
                err_type: error{EmptyBody,FailedRequest,FailedRequestForHtml,InvalidImage},
                icon_id: feed_types.IconRender.ID,
                status_code: http_client.Status = .teapot,
                arena_index: usize,
            },
            skip: struct {arena_index: usize},
        };

        result: Return,
    };
    const Result = IconExistsUnion;
    const SelectResult = std.Io.Select(Result);

    fn check_icons(self: *Self, check_type: IconCheckType) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const progress = std.Progress.start(self.io, .{});
        defer progress.end();
        const progress_node = progress.start("Checking icons", 0);
        defer progress_node.end();

        const select_count: usize = @min(self.core_count, config.core_count_max);

        var buf: [config.core_count_max * @sizeOf(std.heap.ArenaAllocator)]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buf);

        const arenas = fixed.allocator().alloc(std.heap.ArenaAllocator, select_count) catch unreachable;
        for (arenas[0..select_count]) |*arena_fixed| {
            arena_fixed.* = std.heap.ArenaAllocator.init(self.allocator);
        }
        defer {
            for (arenas) |arena_fixed| {
                arena_fixed.deinit();
            }
            fixed.allocator().free(arenas);
        }

        var buf_result: [config.core_count_max]IndexData = undefined;
        var queue = QueueData.init(&buf_result);
        defer queue.close(self.io);

        var end: usize = 0;

        const FnReturn = @typeInfo(@TypeOf(fetch_icon_missing_or_failed)).@"fn".return_type.?;
        var futures: [config.core_count_max]std.Io.Future(FnReturn) = undefined;
        // Make sure futures resources are cleaned up
        defer for (futures[0..end]) |*fut| {
            _ = fut.cancel(self.io) catch {};
        };

        switch (check_type) {
            .missing => {
                const icons_missing = try self.storage.feed_icons_missing(arena.allocator());
                defer arena.allocator().free(icons_missing);
                progress_node.setEstimatedTotalItems(icons_missing.len);

                end = @min(icons_missing.len, select_count);
                for (icons_missing[0..end], 0..) |icon, i| {
                    futures[i] = self.io.async(
                        fetch_icon_missing_or_failed,
                        .{
                            self.io,
                            &arenas[i],
                            &queue,
                            icon.page_url,
                            .{.index_item = i, .index_future = i},
                        }
                    );
                }

                for (icons_missing[end..], 0..) |icon, i| {
                    defer progress_node.completeOne();

                    const result = try queue.getOne(self.io);
                    const icon_result = icons_missing[result.index_item];
                    const icon_new_err = futures[result.index_future].await(self.io);
                    try add_icon_missing(&self.storage, icon_new_err, icon_result);

                    futures[result.index_future] = self.io.async(
                        fetch_icon_missing_or_failed,
                        .{
                            self.io,
                            &arenas[result.index_future],
                            &queue,
                            icon.page_url,
                            .{.index_item = i + end, .index_future = result.index_future},
                        }
                    );
                }

                for (0..end) |_| {
                    defer progress_node.completeOne();

                    const result = try queue.getOne(self.io);
                    const icon_result = icons_missing[result.index_item];
                    const icon_new_err = futures[result.index_future].await(self.io);
                    try add_icon_missing(&self.storage, icon_new_err, icon_result);
                }

            },
            .failed => {
                const icons_failed = try self.storage.feed_icons_failed(arena.allocator());
                progress_node.setEstimatedTotalItems(icons_failed.len);

                end = @min(icons_failed.len, select_count);
                for (icons_failed[0..end], 0..) |icon, i| {
                    futures[i] = self.io.async(
                        fetch_icon_missing_or_failed,
                        .{
                            self.io,
                            &arenas[i],
                            &queue,
                            icon.page_url,
                            .{.index_item = i, .index_future = i},
                        }
                    );
                }

                for (icons_failed[end..], 0..) |icon, i| {
                    defer progress_node.completeOne();

                    const result = try queue.getOne(self.io);
                    const icon_result = icons_failed[result.index_item];
                    const icon_new_err = futures[result.index_future].await(self.io);
                    try add_icon_failed(&self.storage, icon_new_err, icon_result);

                    futures[result.index_future] = self.io.async(
                        fetch_icon_missing_or_failed,
                        .{
                            self.io,
                            &arenas[result.index_future],
                            &queue,
                            icon.page_url,
                            .{.index_item = i + end, .index_future = result.index_future},
                        }
                    );
                }

                for (0..end) |_| {
                    defer progress_node.completeOne();

                    const result = try queue.getOne(self.io);
                    const icon_result = icons_failed[result.index_item];
                    const icon_new_err = futures[result.index_future].await(self.io);
                    try add_icon_failed(&self.storage, icon_new_err, icon_result);
                }
            },
        }

        try self.storage.icons_remove_unused();
    }

    fn fetch_icon_missing_or_failed(io: std.Io, arena: *std.heap.ArenaAllocator, queue: *QueueData, icon_page_url: std.Uri, index_data: IndexData) !feed_types.Icon {
        const result = http_client.fetch_icon(io, arena.allocator(), icon_page_url, .{});
        try queue.putOne(io, index_data);
        return result;
    }

    fn add_icon_missing(storage: *Storage, icon_new_err: anyerror!feed_types.Icon, icon_result: Storage.IconMissing) !void {
        if (icon_new_err) |icon_new| {
            const icon_id = try storage.icon_upsert(icon_new);
            if (icon_id.is_valid()) {
                try storage.feed_icon_update(icon_result.feed_id, icon_id);
            }
        } else |err| {
            std.log.err("Failed to fetch missing icon '{f}'. Error: {}", .{icon_result.page_url, err});
            try storage.icon_failed_add(.{
                .feed_id = icon_result.feed_id,
                .last_msg = "Failed to fetch missing icon",
            });
        }
    }

    fn add_icon_failed(storage: *Storage, icon_new_err: anyerror!feed_types.Icon, icon_result: Storage.IconFailed) !void {
        if (icon_new_err) |icon_new| {
            if (!mem.eql(u8, icon_result.etag_or_last_modified_or_hash, icon_new.etag_or_last_modified_or_hash)) {
                const icon_id = try storage.icon_upsert(icon_new);
                if (icon_id.is_valid()) {
                    try storage.feed_icon_update(icon_result.feed_id, icon_id);
                }
                storage.icon_failed_remove(icon_result.feed_id) catch |err| {
                    std.log.warn("Failed to remove feed from icon_failed table. Error: {}", .{err});
                };
            }
        } else |err| {
            std.log.err("Failed to fetch failed icon '{f}'. Error: {}", .{icon_result.page_url, err});
            try storage.icon_failed_add(.{
                .feed_id = icon_result.feed_id,
                .last_msg = "Failed to fetch failed icon",
            });
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
            \\  serve     Start server
            \\  batch     Do batch actions
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
                .serve => 
                \\Usage: feedgaze serve [options]
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
                \\  --check-missing-icons    Try to fetch icons for feeds that don't have an icon
                \\  --check-failed-icons     Try to fetch icons that have previously failed for some reason 
                \\  -d, --database           Database location 
                \\  -h, --help               Print this help and exit
                ,
            };
        }

        try self.out.writeAll(output);
        try self.out.flush();
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

            for (rules) |r| {
                while (true) {
                    try self.out.print("Remove rule '{s}' -> '{s}'? (y/n) ", .{r.match_url, r.result_url});

                    const raw_value = try self.in.takeDelimiterExclusive('\n');
                    const value = mem.trimStart(u8, raw_value, &std.ascii.whitespace);

                    switch (user_output_state(value)) {
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
        defer tags_arr.deinit(arena.allocator());

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
            try self.out.print("{s} | {f}\n", .{feed.title orelse "<no-title>", feed.page_url orelse feed.feed_url});
        }

        const invalid_msg = "Enter valid input 'y' or 'n'.\n";
        while (true) {
            try self.out.print("{s} tags to {d} feeds? (y/n) ", .{flag_upper_str, feeds.len});
            const raw_value = try self.in.takeDelimiterExclusive('\n');
            const value = mem.trimStart(u8, raw_value, &std.ascii.whitespace);

            switch (user_output_state(value)) {
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
            const tags_ids_buf = try arena.allocator().alloc(feed_types.SqliteId, tags_arr.items.len);
            const tags_ids = try self.storage.tags_ids(tags_arr.items, tags_ids_buf);

            for (feeds) |feed| {
                try self.storage.tags_feed_add(feed.feed_id, tags_ids);
            }
            try self.out.print("Added tags to {d} feed(s).\n", .{feeds.len});
        }
    }

    pub fn add(self: *Self, url_raw: []const u8) !Feed.ID {
        var url = mem.trim(u8, url_raw, &std.ascii.whitespace);
        if (try self.storage.hasFeedWithFeedUrl(url)) {
            return error.FeedExists;
        }

        var uri = std.Uri.parse(url) catch {
            return error.InvalidUrl;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        if (uri.host) |host| {
            const host_str = util.uri_component_val(host);
            const rules = try self.storage.get_rules_for_host(arena.allocator(), host_str);
            defer self.allocator.free(rules);
            if (try AddRule.find_rule_match(uri, rules)) |rule_match| {
                std.log.info("Found matching rule. Using rule to transform url.", .{});
                url = try AddRule.transform_rule_match(self.allocator, uri, rule_match);
            }
        }

        // TODO: reuse client if possible
        var client_2 = http_client.init(self.io, arena.allocator());
        defer client_2.deinit();

        var client = http_client.init(self.io, arena.allocator());
        defer client.deinit();
        var buffer_header: [1024]u8 = undefined;
        
        const feed_uri = try std.Uri.parse(url);
        const feed_opts = try client.fetch(arena.allocator(), feed_uri, .{
            .buffer_header = &buffer_header,
        });

        var add_opts: Storage.AddOptions = .{ .feed_opts = feed_opts.? };
        if (add_opts.feed_opts.content_type == .html) {
            add_opts.feed_opts.content_type = FeedParser.getContentType(add_opts.feed_opts.body) orelse .html;
        }

        var html_opts: ?FeedParser.HtmlOptions = null;

        var buf_url: [1024]u8 = undefined;
        if (add_opts.feed_opts.content_type == .html) {
            const html_parsed = try html.parse_html(arena.allocator(), add_opts.feed_opts.body);
            const links = html_parsed.links;

            if (html_parsed.icon_url) |icon_url| {
                const cache_val = add_opts.feed_opts.feed_updates.etag_or_last_modified;
                add_opts.feed_opts.icon = feed_types.Icon.init_if_data(client.get_uri(), icon_url, cache_val);
            }

            switch (try getUserInput(arena.allocator(), links, self.out, self.in)) {
                .html => |user_html_opts| {
                    add_opts.feed_opts.feed_url = try std.Uri.parse(try client.get_url_slice(&buf_url));
                    html_opts = user_html_opts;
                },
                .index => |index| {
                    const link = links[index];
                    var fetch_url = link.link;
                    var buf: [1024]u8 = undefined;
                    var buf_writer: std.Io.Writer = .fixed(&buf);

                    if (!mem.startsWith(u8, link.link, "http")) {
                        try buf_writer.writeAll(link.link);
                        var url_uri = try std.Uri.parse(url);
                        const result = try url_uri.resolveInPlace(link.link.len, &buf_writer.buffer);
                        const end = buf_writer.end;
                        try buf_writer.print("{f}", .{result.fmt(.all)});
                        fetch_url = buf_writer.buffered()[end..];
                    }

                    uri = std.Uri.parse(fetch_url) catch {
                        return error.InvalidUrl;
                    };

                    if (uri.host) |host| {
                        const host_str = util.uri_component_val(host);
                        const rules = try self.storage.get_rules_for_host(arena.allocator(), host_str);
                        defer self.allocator.free(rules);
                        if (try AddRule.find_rule_match(uri, rules)) |rule_match| {
                            std.log.info("Found matching rule. Using rule to transform url.", .{});
                            fetch_url = try AddRule.transform_rule_match(self.allocator, uri, rule_match);
                        }
                    }

                    const fetch_url_2 = try arena.allocator().dupe(u8, fetch_url);
                    const title = if (link.title) |t| try arena.allocator().dupe(u8, t) else null;
                    const feed_uri_2 = try std.Uri.parse(fetch_url_2);
                    const feed_opts_2 = try client_2.fetch(arena.allocator(), feed_uri_2, .{
                        .buffer_header = &buffer_header,
                    });

                    add_opts.feed_opts = feed_opts_2.?;
                    add_opts.feed_opts.feed_url = try std.Uri.parse(try client_2.get_url_slice(&buf_url));
                    add_opts.feed_opts.title = title;
                }
            }
        } else {
            add_opts.feed_opts.feed_url = try std.Uri.parse(try client.get_url_slice(&buf_url));
        }

        if (add_opts.feed_opts.icon == null) {
            // TODO: feed_url and page_url might have different domains.
            // Favour page_url for domains.
            // Would have to change things in '.index'
            // And not have 'add_opts.feed_opts.feed_url' as input
             
            const feed_uri_for_icon = add_opts.feed_opts.feed_url;
            add_opts.feed_opts.icon = http_client.fetch_icon(self.io, arena.allocator(), feed_uri_for_icon, .{
                .html_body = if (add_opts.feed_opts.content_type == .html) add_opts.feed_opts.body else null,
            }) catch null;
        }

        var parser: FeedParser = .init(self.io, add_opts.feed_opts.body);
        const parsed = try parser.parse(arena.allocator(), html_opts, .{
            .feed_url = add_opts.feed_opts.feed_url,
        });

        const feed = try self.storage.addFeed(parsed, add_opts);
        return feed.feed_id;
    }

    const UserInput = union(enum) {
        index: usize,
        html: FeedParser.HtmlOptions,
    };

    fn getUserInput(allocator: Allocator, links: []html.FeedLink, writer: *std.Io.Writer, reader: *std.Io.Reader) !UserInput {
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
        var index: usize = 0;

        while (index == 0 or index > links.len) {
            try writer.writeAll("Enter number: ");
            try writer.flush();
            reader.tossBuffered();
            const value_raw = try reader.takeDelimiterExclusive('\n');
            const value = mem.trim(u8, value_raw, &std.ascii.whitespace);
            index = std.fmt.parseUnsigned(usize, std.mem.trim(u8, value, &std.ascii.whitespace), 10) catch {
                try writer.print("Provided input '{s}' is not a number. Enter number between 1 - {d}\n", .{value, links.len + 1});
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

    fn html_options(allocator: Allocator, writer: *std.Io.Writer, reader: *std.Io.Reader) !FeedParser.HtmlOptions {
        var opts: FeedParser.HtmlOptions = .{ .selector_container = "" };
        try writer.writeAll("Can enter simple selector that are made up of tag names or classes. Like: '.item div'\n");

        while (true) {
            try writer.writeAll("Enter feed item's selector (required): ");
            try writer.flush();
            reader.tossBuffered();
            const value_raw = try reader.takeDelimiterExclusive('\n');
            // const value_raw = try reader.takeByte();
            print("raw {s}\n", .{value_raw});
            if (get_input_value("test")) |val| {
                opts.selector_container = try allocator.dupe(u8, val);
                break;
            }
            try writer.writeAll("Feed item selector's field is required\n");
        }

        try writer.print("Rest of selector inputs will treat '{s}' selector as root\n", .{opts.selector_container});
        try writer.writeAll("Enter feed item's link selector: ");
        try writer.flush();

        reader.tossBuffered();
        const value_link_selector = try reader.takeDelimiterExclusive('\n');
        if (get_input_value(value_link_selector)) |val| {
            opts.selector_link = try allocator.dupe(u8, val);
        }

        try writer.writeAll("Enter feed item's title selector: ");
        try writer.flush();

        reader.tossBuffered();
        const value_title_selector = try reader.takeDelimiterExclusive('\n');
        if (get_input_value(value_title_selector)) |val| {
            opts.selector_heading = try allocator.dupe(u8, val);
        }

        try writer.writeAll("Enter feed item's date selector: ");
        try writer.flush();
        reader.tossBuffered();
        const value_date_selector = try reader.takeDelimiterExclusive('\n');
        if (get_input_value(value_date_selector)) |val| {
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
        try writer.flush();
        reader.tossBuffered();
        const value_date_fmt = try reader.takeDelimiterExclusive('\n');
        if (get_input_value(value_date_fmt)) |val| {
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

    pub fn update(self: *Self, input: ?[]const u8, options: UpdateOptions) !void {
        try App.update_feeds(self.allocator, self.io, &self.storage, input, options, self.core_count);
    }

    pub fn serve(self: *Self, opts: ServeOptions) !void {
        try @import("server.zig").start_server(self.io, self.storage, opts);
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
            while (true) {
                defer self.out.flush() catch {
                    std.log.warn("Failed to flush subcommand 'remove' text", .{});
                };
                try self.out.print("Delete feed '{f}' (Y/N)? ", .{feed.feed_url});
                try self.out.flush();
                const raw_value = try self.in.takeDelimiterExclusive('\n');
                const value = mem.trim(u8, raw_value, &std.ascii.whitespace);
           
                if (value.len == 1) {
                    if (value[0] == 'y' or value[0] == 'Y') {
                        try self.storage.deleteFeed(feed.feed_id);
                        try self.out.print("Removed feed '{f}'\n", .{feed.feed_url});
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
            _ = try self.out.print("{s} - {f}\n", .{ title, url_out });
            const items = try self.storage.getLatestFeedItemsWithFeedId(arena.allocator(), feed.feed_id, opts);
            if (items.len == 0) {
                _ = try self.out.write("  ");
                _ = try self.out.write("Feed has no items.");
                continue;
            }

            for (items) |item| {
                _ = try self.out.print("\n  {s}\n", .{ item.title });
                if (item.link) |link| {
                    _ = try self.out.print("  {f}\n", .{ link });
                } else {
                    _ = try self.out.writeAll("  <no link>\n");
                }
            }
            _ = try self.out.write("\n");
        }
    }
};

pub fn get_path_db(buf: []u8, init: std.process.Init, path: ?[:0]const u8) !?[*:0]const u8 {
    var fixed_alloc = std.heap.FixedBufferAllocator.init(buf);
    const alloc = fixed_alloc.allocator();

    const db_path: ?[*:0]const u8 = blk: {
        const db_path = path orelse db_path: {
            const kf = @import("known-folders");

            const data_dir = try kf.getPath(init.io, alloc, init.environ_map, .data) orelse unreachable;
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

        break :blk db_path;
    };

    return db_path;
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

    const UpdateResult = union(enum) {
        add: struct { parsed: ValidFeed, feed_updates: FeedUpdate },
        status_code_not_200: struct { status_code: std.http.Status, retry_utc_sec: ?i64 = null },
    };

    pub fn update_feeds(allocator: Allocator, io: std.Io, storage: *Storage, input: ?[]const u8, options: UpdateOptions, core_count: usize) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const feed_updates = try storage.getFeedsToUpdate(arena.allocator(), input, options);
        if (feed_updates.len == 0) {
            std.log.info("No feeds to update", .{});
            return;
        }

        const select_count: usize = @min(core_count, config.core_count_max, feed_updates.len);

        var buf: [config.core_count_max * @sizeOf(std.heap.ArenaAllocator)]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buf);

        const arenas = fixed.allocator().alloc(std.heap.ArenaAllocator, select_count) catch unreachable;
        for (arenas[0..select_count]) |*arena_fixed| {
            arena_fixed.* = std.heap.ArenaAllocator.init(allocator);
        }
        defer {
            for (arenas) |arena_fixed| {
                arena_fixed.deinit();
            }
            fixed.allocator().free(arenas);
        }

        var buf_result: [config.core_count_max]IndexData = undefined;
        var queue = QueueData.init(&buf_result);
        defer queue.close(io);

        const end = select_count;

        const FnReturn = @typeInfo(@TypeOf(update_feed)).@"fn".return_type.?;
        var futures: [config.core_count_max]std.Io.Future(FnReturn) = undefined;
        // Make sure futures resources are cleaned up
        defer for (futures[0..end]) |*fut| {
            _ = fut.cancel(io) catch {};
        };

        var count_updated: u32 = 0;

        const progress = std.Progress.start(io, .{});
        defer progress.end();
        const progress_node = progress.start("Updating feeds", feed_updates.len);
        defer {
            progress_node.end();
            std.log.info("Feeds updated: [{}/{}]", .{count_updated, feed_updates.len});
        }

        for (feed_updates[0..end], 0..) |f_update, i| {
            futures[i] = io.async(
                update_feed,
                .{
                    io,
                    &arenas[i],
                    &queue,
                    storage,
                    f_update,
                    .{.index_item = i, .index_future = i},
                }
            );
        }

        for (feed_updates[end..], 0..) |f_update, i| {
            const indexes = try queue.getOne(io);
            const queue_update = feed_updates[indexes.index_item];
            const result_err = futures[indexes.index_future].await(io);

            count_updated += @intFromBool(try resolve_update_result(storage, result_err, queue_update));

            progress_node.completeOne();

            futures[indexes.index_future] = io.async(
                update_feed,
                .{
                    io,
                    &arenas[indexes.index_future],
                    &queue,
                    storage,
                    f_update,
                    .{.index_item = i + end, .index_future = indexes.index_future},
                }
            );
        }

        for (0..end) |_| {
            const indexes = try queue.getOne(io);
            const queue_update = feed_updates[indexes.index_item];
            const result_err = futures[indexes.index_future].await(io);

            _ = try resolve_update_result(storage, result_err, queue_update);

            progress_node.completeOne();
        }
    }

    fn resolve_update_result(storage: *Storage, result_err: anyerror!UpdateResult, queue_update: FeedToUpdate) !bool {
        if (result_err) |result| switch (result) {
            .add => |r| {
                storage.updateFeedAndItems(r.parsed, r.feed_updates) catch |err| {
                    try storage.request_failed_add(queue_update.feed_id, @errorName(err));
                    std.log.err("Failed to update feed '{f}'. Error: {}", .{queue_update.feed_url, err});
                    try storage.rate_limit_remove(queue_update.feed_id);
                };

                return true;
            },
            .status_code_not_200 => |val| switch (val.status_code) {
                .not_modified => {
                    try storage.updateLastUpdate(queue_update.feed_id);
                    try storage.request_failed_remove(queue_update.feed_id);
                    try storage.rate_limit_remove(queue_update.feed_id);
                },
                .too_many_requests => {
                    try storage.rate_limit_add(queue_update.feed_id, val.retry_utc_sec orelse unreachable);
                    try storage.request_failed_remove(queue_update.feed_id);
                },
                else => {
                    try storage.rate_limit_remove(queue_update.feed_id);
                    var buf_status_code: [16]u8 = undefined;
                    const reason = val.status_code.phrase() orelse
                        std.fmt.bufPrint(&buf_status_code, "{d}", .{val.status_code}) catch unreachable;
                    try storage.request_failed_add(queue_update.feed_id, reason);
                }
            }
        } else |err| switch (err) {
            error.NameServerFailure, error.NetworkUnreachable => {
                std.log.err("There seems to be no network available", .{});
                return err;
            },
            else => {
                std.log.err("Failed to update feed '{f}'. Error: {}", .{queue_update.feed_url, err});
                try storage.rate_limit_remove(queue_update.feed_id);
                try storage.request_failed_add(queue_update.feed_id, @errorName(err));
            }
        }
        return false;
    }

    pub fn update_feed(io: std.Io, arena: *std.heap.ArenaAllocator, queue: *QueueData, storage: *Storage, f_update: FeedToUpdate, index_data: IndexData) !UpdateResult {
        _ = arena.reset(.retain_capacity);

        var req = http_client.init(io, arena.allocator());
        defer req.deinit();

        var buffer_header: [1028]u8 = undefined;
        const feed_uri = f_update.feed_url;
        const resp_opt = try req.fetch(arena.allocator(), feed_uri, .{
            .etag_or_last_modified = f_update.etag_or_last_modified,
            .buffer_header = &buffer_header,
        });

        if (resp_opt == null) {
            const resp = req.response orelse unreachable;
            const status_code = resp.head.status;
            // resp_opt null means status_code != 200. maybe change it?
            std.debug.assert(status_code != .ok);

            const retry_utc_sec = blk: {
                if (status_code == .too_many_requests) {
                    std.log.warn("Rate limit hit with feed '{f}'", .{f_update.feed_url});
                    const now_utc_sec = std.Io.Clock.real.now(io).toSeconds();

                    var header_map: http_client.HeaderMap = .empty;
                    try header_map.ensureTotalCapacity(arena.allocator(), 4);
                    try http_client.fill_headers(req.response.?.head.bytes, &header_map, &.{
                       "x-ratelimit-remaining",
                        "x-ratelimit-reset",
                        "retry-after",
                        "x-rate-limit-reset",
                    });
                    if (header_map.get("x-ratelimit-remaining")) |remaining| {
                        const raw = remaining;
                        std.debug.assert(raw.len > 0);
                        const value = try std.fmt.parseFloat(f32, raw);
                        if (value <= 0.0) {
                            if (header_map.get("x-ratelimit-reset")) |header| {
                                if (std.fmt.parseUnsigned(i64, header, 10)) |nr| {
                                    std.log.debug("x-ratelimit-reset", .{});
                                    break :blk now_utc_sec + nr + 1;
                                } else |_| {}
                            }
                        }
                    }

                    if (header_map.get("retry-after") orelse 
                        header_map.get("x-ratelimit-reset")) |header| {
                            const raw = header;
                            std.log.debug("header rate-limit: {s}", .{raw});
                            if (std.fmt.parseUnsigned(i64, raw, 10)) |nr| {
                                break :blk now_utc_sec + nr + 1;
                            } else |_| {}

                            if (feed_types.RssDateTime.parse(raw)) |date_utc| {
                                break :blk date_utc + 1;
                            } else |_| {}
                    }

                    break :blk now_utc_sec + std.time.s_per_hour;
                }

                break :blk null;
            };

            try queue.putOne(io, index_data);
            return .{.status_code_not_200 = .{.status_code = status_code, .retry_utc_sec = retry_utc_sec }};
        }

        const resp = resp_opt orelse unreachable;
        const body = resp.body;

        // TODO: maybe move getting html_options outside this fn
        const html_options = try storage.html_selector_get(arena.allocator(), f_update.feed_id);
        var parsing: FeedParser = .init(io, body);

        const parsed = try parsing.parse(arena.allocator(), html_options, .{
            .feed_url = feed_uri,
            .feed_id = f_update.feed_id,
            .feed_to_update = f_update,
        });

        try queue.putOne(io, index_data);
        return .{ .add = .{.parsed = parsed, .feed_updates = resp.feed_updates }};
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
    defer arr.deinit(allocator);
    for (inputs) |pos| {
        arr.appendAssumeCapacity(pos);
    }

    return arr.toOwnedSlice(allocator);
}
