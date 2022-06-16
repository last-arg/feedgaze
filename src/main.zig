const std = @import("std");
const log = std.log;
const sql = @import("sqlite");
const mem = std.mem;
const print = std.debug.print;
const process = std.process;
const Allocator = std.mem.Allocator;
const command = @import("cli.zig");
const Storage = @import("feed_db.zig").Storage;
const Cli = command.Cli;
const clap = @import("clap");
const known_folders = @import("known-folders");
const server = @import("server.zig");

// NOTE: This will return error.CouldNotConnect when adding url
// pub const io_mode = .evented;

pub const log_level = std.log.Level.debug;
pub const known_folders_config = .{
    .xdg_on_mac = true,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const base_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const args = try parseArgs(arena.allocator());

    for (required_subcommands) |required| {
        if (required == args.command and args.pos_args == null) {
            log.err("Subcommand '{s}' requires input(s)", .{@tagName(args.command)});
            return error.SubcommandRequiresInput;
        }
    }

    var storage = blk: {
        var tmp_arena = std.heap.ArenaAllocator.init(base_allocator);
        defer tmp_arena.deinit();
        const tmp_allocator = tmp_arena.allocator();
        if (args.db_path != null and mem.eql(u8, ":memory:", args.db_path.?)) {
            break :blk try Storage.init(arena_allocator, null);
        }
        var db_location = try getDatabaseLocation(tmp_allocator, args.db_path);
        break :blk try Storage.init(arena_allocator, db_location);
    };

    var writer = std.io.getStdOut().writer();
    const reader = std.io.getStdIn().reader();
    const cli_options = command.CliOptions{ .default = args.default, .force = args.force };
    var cli = command.makeCli(arena_allocator, &storage, cli_options, writer, reader);
    switch (args.command) {
        .server => {
            var sessions = server.Sessions.init(arena_allocator);
            defer sessions.deinit();
            var s = try server.Server.init(arena_allocator, &storage, &sessions);
            try s.run();
            defer s.shutdown();
        },
        .add => try cli.addFeed(args.pos_args.?, args.tags orelse &.{}),
        .update => try cli.updateFeeds(),
        .remove => try cli.deleteFeed(args.pos_args.?),
        .search => try cli.search(args.pos_args.?),
        .clean => try cli.cleanItems(),
        .tag => {
            try cli.tagCmd(args.pos_args.?, args.tag_args.?);
        },
        .print => {
            try cli.printCmd(args.print_action, args.tags);
        },
        // .@"print-feeds" => try cli.printFeeds(),
        // .@"print-items" => try cli.printAllItems(),
    }
}

fn getDatabaseLocation(allocator: Allocator, location_opt: ?[]const u8) ![:0]const u8 {
    if (location_opt) |loc| {
        const db_file = block: {
            if (std.fs.path.isAbsolute(loc)) {
                break :block try std.mem.joinZ(allocator, loc, &.{});
            } else if (loc[0] == '~') {
                const home = std.os.getenv("HOME") orelse return error.NoEnvHome;
                break :block try std.fs.path.joinZ(allocator, &.{ home, loc[1..] });
            }
            break :block try std.fs.path.joinZ(allocator, &.{ try std.process.getCwdAlloc(allocator), loc });
        };
        std.fs.accessAbsolute(db_file, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("Provided path '{s}' doesn't exist\n", .{db_file});
                var buf: [1]u8 = undefined;
                while (true) {
                    try stderr.print("Do you want to create database in '{s}' (Y/n)? ", .{db_file});
                    _ = try std.io.getStdIn().read(&buf);
                    const first = buf[0];
                    // Clear characters from stdin
                    while ((try std.io.getStdIn().read(&buf)) != 0) if (buf[0] == '\n') break;
                    const char = std.ascii.toLower(first);
                    if (char == 'y') {
                        break;
                    } else if (char == 'n') {
                        print("Exit app\n", .{});
                        std.os.exit(0);
                    }
                    try stderr.print("Invalid input '{s}' try again.\n", .{db_file});
                }
            },
            else => return err,
        };
        const db_dir = std.fs.path.dirname(db_file).?;
        std.fs.makeDirAbsolute(db_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                log.err("Failed to create directory in '{s}' for database file feedgaze.sqlite", .{db_dir});
                return err;
            },
        };
        return db_file;
    }
    // Get default database location
    const db_file = block: {
        if (try known_folders.getPath(allocator, .local_configuration)) |path| {
            break :block try std.fs.path.joinZ(allocator, &.{ path, "feedgaze", "feedgaze.sqlite" });
        }
        const builtin = @import("builtin");
        if (builtin.target.os.tag == .linux) {
            if (try known_folders.getPath(allocator, .home)) |path| {
                break :block try std.fs.path.joinZ(allocator, &.{ path, ".config", "feedgaze", "feedgaze.sqlite" });
            }
        }
        log.err("Failed to find local configuration or home directory\n", .{});
        return error.MissingConfigAndHomeDir;
    };
    const db_dir = std.fs.path.dirname(db_file).?;
    std.fs.makeDirAbsolute(db_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.err("Failed to create directory in '{s}' for database file feedgaze.sqlite", .{db_dir});
            return err;
        },
    };
    return db_file;
}

const help_param = clap.Param(clap.Help){
    .id = .{ .val = "help", .desc = "Display this help and exit." },
    .names = .{ .short = 'h', .long = "help" },
};

const db_param = clap.Param(clap.Help){
    .id = .{ .val = "db", .desc = "Path to database/storage." },
    .names = .{ .long = "db" },
    .takes_value = .one,
};

const default_param = clap.Param(clap.Help){
    .id = .{ .val = "default", .desc = "Provide index to autopick if there is more than one option." },
    .names = .{ .short = 'd', .long = "default" },
    .takes_value = .one,
};

const params = struct {
    const add = &[_]clap.Param(clap.Help){
        default_param,
        .{
            .id = .{ .val = "tags", .desc = "Add tags to feed (comma separated)." },
            .names = .{ .short = 't', .long = "tags" },
            .takes_value = .many,
        },
        db_param,
        help_param,
        .{ .id = .{ .val = "url" }, .takes_value = .many },
    };

    const remove = &[_]clap.Param(clap.Help){
        default_param,
        db_param,
        help_param,
        .{ .id = .{ .val = "searches" }, .takes_value = .many },
    };

    const update = &[_]clap.Param(clap.Help){
        .{
            .id = .{ .val = "force", .desc = "Force update all feeds." },
            .names = .{ .short = 'f', .long = "force" },
        },
        db_param,
        help_param,
    };

    const search = &[_]clap.Param(clap.Help){
        db_param,
        help_param,
        .{ .id = .{ .val = "searches" }, .takes_value = .many },
    };

    const clean = &[_]clap.Param(clap.Help){ db_param, help_param };

    const print = &[_]clap.Param(clap.Help){
        .{
            .id = .{ .val = "feeds", .desc = "Print most recently updated feeds." },
            .names = .{ .short = 'f', .long = "feeds" },
        },
        .{
            .id = .{ .val = "items", .desc = "Print most recently updated items." },
            .names = .{ .short = 'i', .long = "items" },
        },
        .{
            .id = .{ .val = "tags", .desc = "Only display feeds or items with these tags. To print all tags don't provide any input." },
            .names = .{ .short = 't', .long = "tags" },
        },
        db_param,
        help_param,
    };

    const tag = &[_]clap.Param(clap.Help){
        .{
            .id = .{ .val = "id", .desc = "Feed's id." },
            .names = .{ .long = "id" },
            .takes_value = .one,
        },
        .{
            .id = .{ .val = "url", .desc = "Feed's url." },
            .names = .{ .short = 'u', .long = "url" },
            .takes_value = .one,
        },
        db_param,
        help_param,
        .{ .id = .{ .val = "tag" }, .takes_value = .many },
    };

    const server = &[_]clap.Param(clap.Help){ db_param, help_param };
};
const Subcommand = std.meta.DeclEnum(params);

const ParsedCli = struct {
    command: Subcommand,
    db_path: ?[]const u8 = null,
    default: ?i32 = null,
    tags: ?[][]const u8 = null,
    print_action: ?command.PrintAction = null,
    tag_args: ?command.TagArgs = null,
    force: bool = false,
    pos_args: ?[][]const u8 = null,
};

pub fn printSubcommandHelp(sub_params: []const clap.Param(clap.Help), subcmd: []const u8, example: ?[]const u8) !void {
    const stderr_writer = std.io.getStdErr().writer();
    try stderr_writer.print("feedgaze {s} ", .{subcmd});
    try clap.usage(stderr_writer, clap.Help, sub_params);
    try stderr_writer.writeAll("\n\n");
    if (example) |e| {
        const example_fmt =
            \\Example: feedgaze {s} {s}
            \\
            \\
        ;
        try stderr_writer.print(example_fmt, .{ subcmd, e });
    }
    try clap.help(stderr_writer, clap.Help, sub_params, .{});
}

pub fn parseArgs(allocator: Allocator) !ParsedCli {
    const stderr_writer = std.io.getStdErr().writer();
    var iter = try process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();

    const subcmd_str = iter.next() orelse {
        const subcmd_output = comptime blk: {
            const decls = std.meta.declarations(params);
            comptime var result: []const u8 = decls[0].name;
            inline for (decls[1..]) |decl| {
                result = result ++ ", " ++ decl.name;
            }
            break :blk result;
        };
        log.err("No subcommand provided. See 'feedgaze --help'.\nSubcommands: {s}", .{subcmd_output});
        return error.NoSubcommandProvided;
    };

    if (mem.eql(u8, subcmd_str, "--help") or mem.eql(u8, subcmd_str, "-h")) {
        try stderr_writer.writeAll("Usage: feedgaze <subcommand> [subcommand action] [options] [inputs]\n");
        inline for (comptime std.meta.declarations(params)) |decl| {
            try stderr_writer.print("\nSubcommand: {s}\n", .{decl.name});
            try clap.help(stderr_writer, clap.Help, @field(params, decl.name), .{});
        }
        std.os.exit(0);
    }

    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_str) orelse {
        log.err("Unknown subcommand '{s}'. See 'feedgaze --help'", .{subcmd_str});
        // TODO: suggest closest match to unknown subcommand
        // https://en.wikipedia.org/wiki/Damerau%E2%80%93Levenshtein_distance
        return error.UnknownSubcommand;
    };

    const subcmd_params = blk: {
        var s_params: []const clap.Param(clap.Help) = undefined;
        // NOTE: 'inline for' doesn't like the use of 'break'
        inline for (comptime std.meta.declarations(params)) |decl| {
            if (std.meta.stringToEnum(Subcommand, decl.name) == subcmd) {
                s_params = @field(params, decl.name);
            }
        }
        break :blk s_params;
    };

    var diag = clap.Diagnostic{};
    var parser = clap.streaming.Clap(clap.Help, process.ArgIterator){
        .params = subcmd_params,
        .iter = &iter,
        .diagnostic = &diag,
    };

    var pos_args = std.ArrayList([]const u8).init(allocator);
    defer pos_args.deinit();
    var tags = std.ArrayList([]const u8).init(allocator);
    defer tags.deinit();

    var parsed_args = ParsedCli{ .command = subcmd };
    switch (subcmd) {
        .add => {
            while (parser.next() catch |err| {
                diag.report(stderr_writer, err) catch {};
                return err;
            }) |arg| {
                const param_id = arg.param.id.val;
                if (mem.eql(u8, param_id, "url")) {
                    if (arg.value) |pos| {
                        try pos_args.append(pos);
                    }
                } else if (mem.eql(u8, param_id, "tags")) {
                    if (arg.value) |tags_raw| {
                        var tags_iter = mem.split(u8, tags_raw, ",");
                        while (tags_iter.next()) |tag| {
                            try tags.append(mem.trim(u8, tag, " "));
                        }
                    }
                } else if (mem.eql(u8, param_id, "default")) {
                    if (arg.value) |value| {
                        parsed_args.default = try std.fmt.parseInt(i32, value, 10);
                    }
                } else if (mem.eql(u8, param_id, "db")) {
                    parsed_args.db_path = arg.value;
                } else if (mem.eql(u8, param_id, "help")) {
                    try printSubcommandHelp(subcmd_params, subcmd_str, "--tags \"tag1,tag2\" <url>...");
                    try clap.help(stderr_writer, clap.Help, subcmd_params, .{});
                    std.os.exit(0);
                }
            }
        },
        .remove => {
            while (parser.next() catch |err| {
                diag.report(stderr_writer, err) catch {};
                return err;
            }) |arg| {
                const param_id = arg.param.id.val;
                if (mem.eql(u8, param_id, "searches")) {
                    if (arg.value) |value| {
                        try pos_args.append(value);
                    }
                } else if (mem.eql(u8, param_id, "default")) {
                    if (arg.value) |value| {
                        parsed_args.default = try std.fmt.parseInt(i32, value, 10);
                    }
                } else if (mem.eql(u8, param_id, "db")) {
                    parsed_args.db_path = arg.value;
                } else if (mem.eql(u8, param_id, "help")) {
                    try printSubcommandHelp(subcmd_params, subcmd_str, "<searches>...");
                    std.os.exit(0);
                }
            }
        },
        .update => {
            while (parser.next() catch |err| {
                diag.report(stderr_writer, err) catch {};
                return err;
            }) |arg| {
                const param_id = arg.param.id.val;
                if (mem.eql(u8, param_id, "force")) {
                    parsed_args.force = true;
                } else if (mem.eql(u8, param_id, "db")) {
                    parsed_args.db_path = arg.value;
                } else if (mem.eql(u8, param_id, "help")) {
                    try printSubcommandHelp(subcmd_params, subcmd_str, "");
                    std.os.exit(0);
                }
            }
        },
        .search => {
            while (parser.next() catch |err| {
                diag.report(stderr_writer, err) catch {};
                return err;
            }) |arg| {
                const param_id = arg.param.id.val;
                if (mem.eql(u8, param_id, "searches")) {
                    if (arg.value) |value| {
                        try pos_args.append(value);
                    }
                } else if (mem.eql(u8, param_id, "db")) {
                    parsed_args.db_path = arg.value;
                } else if (mem.eql(u8, param_id, "help")) {
                    try printSubcommandHelp(subcmd_params, subcmd_str, null);
                    std.os.exit(0);
                }
            }
        },
        .clean, .server => {
            while (parser.next() catch |err| {
                diag.report(stderr_writer, err) catch {};
                return err;
            }) |arg| {
                const param_id = arg.param.id.val;
                if (mem.eql(u8, param_id, "db")) {
                    parsed_args.db_path = arg.value;
                } else if (mem.eql(u8, param_id, "help")) {
                    try printSubcommandHelp(subcmd_params, subcmd_str, null);
                    std.os.exit(0);
                }
            }
        },
        .print => {
            while (parser.next() catch |err| {
                diag.report(stderr_writer, err) catch {};
                return err;
            }) |arg| {
                const param_id = arg.param.id.val;
                if (mem.eql(u8, param_id, "feeds")) {
                    if (parsed_args.print_action) |action| {
                        if (action == .items) {
                            log.err("Subcommand 'print' can only have one these flags: --feeds, --items", .{});
                        }
                    }
                    parsed_args.print_action = .feeds;
                } else if (mem.eql(u8, param_id, "items")) {
                    if (parsed_args.print_action) |action| {
                        if (action == .feeds) {
                            log.err("Subcommand 'print' can only have one these flags: --feeds, --items", .{});
                        }
                    }
                    parsed_args.print_action = .items;
                } else if (mem.eql(u8, param_id, "tags")) {
                    parsed_args.tags = &.{};
                } else if (mem.eql(u8, param_id, "db")) {
                    parsed_args.db_path = arg.value;
                } else if (mem.eql(u8, param_id, "help")) {
                    try printSubcommandHelp(subcmd_params, subcmd_str, null);
                    std.os.exit(0);
                }
            }

            if (parsed_args.print_action == null and parsed_args.tags == null) {
                log.err("Subcommand 'print' requires one of these flags: --feeds, --items, --tags", .{});
                std.os.exit(0);
            }
        },
        .tag => {
            // subcommand + actions is 'tag <add|remove>'
            var buf: [32]u8 = undefined;
            const action_str = blk: {
                const enum_tags = comptime std.meta.fields(command.TagActionCmd);
                comptime var result = enum_tags[0].name;
                inline for (enum_tags[1..]) |tag| result = result ++ "|" ++ tag.name;
                break :blk "<" ++ result ++ ">";
            };
            const tag_action_cmd = blk: {
                const enum_tags = comptime std.meta.fields(command.TagActionCmd);
                comptime var actions_output = enum_tags[0].name;
                inline for (enum_tags[1..]) |tag| {
                    actions_output = actions_output ++ ", " ++ tag.name;
                }
                const arg = (parser.next() catch |err| {
                    diag.report(stderr_writer, err) catch {};
                    return err;
                }) orelse {
                    log.err("'tag' subcommand requires one these action commands: {s}", .{actions_output});
                    return error.MissingSubcommandAction;
                };
                if (mem.eql(u8, arg.param.id.val, "help")) {
                    const str = try std.fmt.bufPrint(&buf, "{s} {s}", .{ subcmd_str, action_str });
                    try printSubcommandHelp(subcmd_params, str, null);
                    std.os.exit(0);
                }
                const value = arg.value orelse {
                    log.err("'tag' subcommand requires one these action commands: {s}", .{actions_output});
                    return error.MissingSubcommandAction;
                };

                break :blk std.meta.stringToEnum(command.TagActionCmd, value) orelse {
                    log.err("Invalid action command '{s}' provided to 'tag' subcommand. Valid 'tag' action commands: {s}", .{ value, actions_output });
                    return error.UnknownSubcommandAction;
                };
            };

            parsed_args.tag_args = .{ .action = tag_action_cmd };
            while (parser.next() catch |err| {
                diag.report(stderr_writer, err) catch {};
                return err;
            }) |arg| {
                const param_id = arg.param.id.val;
                if (mem.eql(u8, param_id, "tag")) {
                    if (arg.value) |value| {
                        try pos_args.append(value);
                    }
                } else if (mem.eql(u8, param_id, "id")) {
                    if (arg.value) |value| {
                        parsed_args.tag_args.?.id = try std.fmt.parseUnsigned(u64, value, 10);
                    }
                } else if (mem.eql(u8, param_id, "url")) {
                    parsed_args.tag_args.?.url = arg.value;
                } else if (mem.eql(u8, param_id, "db")) {
                    parsed_args.db_path = arg.value;
                } else if (mem.eql(u8, param_id, "help")) {
                    const str = try std.fmt.bufPrint(&buf, "{s} {s}", .{ subcmd_str, action_str });
                    try printSubcommandHelp(subcmd_params, str, null);
                    std.os.exit(0);
                }
            }

            // Make sure there is only one of these flags: --id, --url
            const has_id = parsed_args.tag_args.?.id != null;
            const has_url = parsed_args.tag_args.?.url != null;
            if (has_id and has_url) {
                log.err("Subcommand 'tag <add|remove>' can only have one these flags '--id' or '--url'", .{});
                std.os.exit(0);
            } else if (!has_id and !has_url) {
                log.err("Subcommand 'tag <add|remove>' must have one these flags '--id' or '--url'", .{});
                std.os.exit(0);
            }
        },
    }

    if (pos_args.items.len > 0) {
        parsed_args.pos_args = pos_args.toOwnedSlice();
    }

    if (tags.items.len > 0) {
        parsed_args.tags = tags.toOwnedSlice();
    }

    return parsed_args;
}

// Makes two assumtions:
// 1) positional arg is last one.
// 2) positional arg's id.desc value is empty ("")
const required_subcommands = blk: {
    var len: u32 = 0;
    inline for (std.meta.declarations(params)) |decl| {
        const s_params = @field(params, decl.name);
        const last = s_params[s_params.len - 1];
        if (last.id.desc.len == 0) len += 1;
    }
    var cmds: [len]Subcommand = undefined;
    var index: u32 = 0;
    inline for (std.meta.declarations(params)) |decl| {
        const s_params = @field(params, decl.name);
        const last = s_params[s_params.len - 1];
        if (last.id.desc.len == 0) {
            const subcmd = std.meta.stringToEnum(Subcommand, decl.name).?;
            cmds[index] = subcmd;
            index += 1;
        }
    }
    break :blk cmds;
};
