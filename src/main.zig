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

pub const log_level = std.log.Level.debug;
pub const known_folders_config = .{
    .xdg_on_mac = true,
};

// TODO: need to replace disk db, doesn't work with new code anymore
// TODO: auto add some data for fast cli testing

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const base_allocator = gpa.allocator();
    // const base_allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help     Display this help and exit.") catch unreachable,
        clap.parseParam("--db <STR>     Point to sqlite database location. Default: '~/.config/feedgaze/feedgaze.sqlite'.") catch unreachable,
        clap.parseParam("-u, --url      Apply action only to url feeds.") catch unreachable,
        clap.parseParam("-l, --local    Apply action only to local feeds.") catch unreachable,
        clap.parseParam("-f, --force    Force update all feeds. Subcommand: update") catch unreachable,
        // TODO: implement '--default' flag. Can have none to multiple values. Do comma separate values?
        // Probably have to use StreamingClap
        clap.parseParam("-d, --default <NUM> Automatically select (space separated) values.") catch unreachable,
        clap.parseParam("<POS>") catch unreachable,
    };

    errdefer print("TODO: print usage\n", .{});

    var diag = clap.Diagnostic{};
    var args = clap.parse(clap.Help, &params, .{ .diagnostic = &diag }) catch |err| {
        // Report useful error and exit
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer args.deinit();

    if (args.positionals().len == 0) {
        log.err("No subcommand entered.", .{});
        return error.MissingSubCommand;
    }

    const Subcommand = enum { add, update, delete, search, clean, @"print-items", @"print-feeds" };
    const subcommand_arg = args.positionals()[0];
    const subcommand = std.meta.stringToEnum(Subcommand, subcommand_arg) orelse {
        log.err("Invalid subcommand '{s}' entered.\n", .{subcommand_arg});
        return error.InvalidSubcommand;
    };

    // TODO: use more than one value for inputs in fns where possible?
    const inputs = args.positionals()[1..];
    const commands_with_pos = [_]Subcommand{ .add, .delete, .search };
    const has_subcommand = blk: {
        for (commands_with_pos) |com| {
            if (com == subcommand) break :blk true;
        }
        break :blk false;
    };

    if (has_subcommand and inputs.len == 0) {
        log.err("Subcommand '{s}' requires input(s)\n", .{subcommand_arg});
        return error.SubcommandRequiresInput;
    }

    for (inputs) |value| {
        log.info("{s}", .{value});
    }

    var storage = blk: {
        var tmp_arena = std.heap.ArenaAllocator.init(base_allocator);
        defer tmp_arena.deinit();
        const tmp_allocator = tmp_arena.allocator();
        const path_opt = args.option("--db");
        if (path_opt) |path| {
            if (mem.eql(u8, ":memory:", path)) break :blk try Storage.init(arena_allocator, null);
        }
        var db_location = try getDatabaseLocation(tmp_allocator, path_opt);
        break :blk try Storage.init(arena_allocator, db_location);
    };

    const cli_options = .{
        .force = args.flag("--force"),
        .url = args.flag("--url") or !args.flag("--local"),
        .local = args.flag("--local") or !args.flag("--url"),
    };

    var writer = std.io.getStdOut().writer();
    const reader = std.io.getStdIn().reader();
    var cli = command.makeCli(arena_allocator, &storage, cli_options, writer, reader);
    switch (subcommand) {
        .add => try cli.addFeed(inputs),
        .update => try cli.updateFeeds(),
        // TODO: multiple values will be OR-ed
        .delete => try cli.deleteFeed(inputs[0]),
        // TODO: multiple values will be OR-ed
        .search => try cli.search(inputs[0]),
        .clean => try cli.cleanItems(),
        .@"print-feeds" => try cli.printFeeds(),
        .@"print-items" => try cli.printAllItems(),
    }
}

fn getDatabaseLocation(allocator: Allocator, db_option: ?[]const u8) ![:0]const u8 {
    if (db_option) |loc| {
        const db_file = block: {
            if (std.fs.path.isAbsolute(loc)) {
                break :block try std.mem.joinZ(allocator, loc, &.{});
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
