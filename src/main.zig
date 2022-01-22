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
    const base_allocator = std.heap.page_allocator;
    // const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = allocator;

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help     Display this help and exit.") catch unreachable,
        clap.parseParam("--db <STR>     Point to sqlite database location. Default: '~/.config/feedgaze/feedgaze.sqlite'") catch unreachable,
        clap.parseParam("-u, --url      Apply action only to url feeds.") catch unreachable,
        clap.parseParam("-l, --local    Apply action only to local feeds.") catch unreachable,
        clap.parseParam("-f, --force    Force update all feeds. Subcommand: update") catch unreachable,
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
        log.err("No subcommand entered.\n", .{});
        return error.MissingSubCommand;
    }

    const Subcommand = enum { add, update, delete, search, clean, print };
    const subcommand_arg = args.positionals()[0];
    const subcommand = std.meta.stringToEnum(Subcommand, subcommand_arg) orelse {
        log.err("Invalid subcommand '{s}' entered.\n", .{subcommand_arg});
        return error.InvalidSubcommand;
    };

    const inputs = args.positionals()[1..];
    const commands = [_]Subcommand{ .add, .delete, .search };
    const require_input = blk: {
        for (commands) |com| {
            if (com == subcommand) break :blk true;
        }
        break :blk false;
    };

    if (require_input and inputs.len == 0) {
        log.err("Subcommand '{s}' requires input(s)\n", .{subcommand_arg});
        return error.SubcommandRequiresInput;
    }

    // TODO: add flag for sqlite db file location
    var db_location: []const u8 = blk: {
        if (args.option("--db")) |loc| {
            _ = loc;
            // TODO
        }
        const db_file = block: {
            if (try known_folders.getPath(allocator, .local_configuration)) |path| {
                break :block try std.fs.path.join(allocator, &.{ path, "feedgaze", "feedgaze.sqlite" });
            }
            if (try known_folders.getPath(allocator, .home)) |path| {
                // TODO: '.config' might be different on other platforms
                break :block try std.fs.path.join(allocator, &.{ path, ".config", "feedgaze", "feedgaze.sqlite" });
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
        break :blk db_file;
    };

    print("db_location: {s}\n", .{db_location});

    // TODO: handle db path
    // const abs_location = "/media/hdd/code/feedgaze/tmp/test.db_conn";
    // const abs_location = null;
    // TODO: make default location somewhere in home directory
    // const abs_location = try makeFilePath(allocator, default_feed_dblocation);
    // const feed_dbfile = try std.fs.createFileAbsolute(
    //     abs_location,
    //     .{ .read = true, .truncate = false },
    // );
    // TODO: create db
    // var storage = try Storage.init(allocator, abs_location);
    // var writer = std.io.getStdOut().writer();
    // const reader = std.io.getStdIn().reader();

    const cli_options = .{
        .force = args.flag("--force"),
        .url = args.flag("--url") or !args.flag("--local"),
        .local = args.flag("--local") or !args.flag("--url"),
    };

    print("subcommand: {s}\n", .{subcommand});
    print("options: {}\n", .{cli_options});

    // var cli = command.makeCli(allocator, &storage, writer, reader);
    switch (subcommand) {
        .add => {},
        .update => {},
        .delete => {},
        .search => {},
        .clean => {},
        .print => {},
    }

    // If flag isn't use use default location
    // {
    // if (db_flag) {
    //     // resolve to absolute path
    //     if (make_sure_file_exists) {
    //         return file_abs_loc;
    //     } else {
    //         "Do you want to create database in '<absolute path>'"
    //         if (create) {
    //             // makeDirs()
    //             return file_abs_loc;
    //         } else {
    //             // exit err code
    //         }
    //     }
    // } else {
    //     if (XDG_CONFIG_HOME) {
    //         return XDG_CONFIG_HOME;
    //     } else if (HOME) {
    //         return $HOME/.config;
    //     } else {
    //         log.err("No XDG_CONFIG_HOME or HOME environment variable set\n", .{});
    //         log.err("Set one of the variables or use flag --db <location>\n", .{});
    //         // exit err code
    //     }
    //     // construct file loc: <abs_config_dir>/feedgaze/feedgaze.sqlite
    //     // makeDirs()
    // }
    // }

    // var iter = process.args();
    // _ = iter.skip();
    // while (try iter.next(allocator)) |arg| {
    //     if (mem.eql(u8, "add", arg)) {
    //         if (try iter.next(allocator)) |value| {
    //             ;
    //         } else {
    //             log.err("Subcommand add missing feed (url or file) location", .{});
    //         }
    //     } else if (mem.eql(u8, "update", arg)) {
    //         var opts = command.CliOptions{ .url = false, .local = false };
    //         while (try iter.next(allocator)) |value| {
    //             if (mem.eql(u8, "--url", value)) {
    //                 opts.url = true;
    //             } else if (mem.eql(u8, "--local", value)) {
    //                 opts.local = true;
    //             } else if (mem.eql(u8, "--force", value)) {
    //                 opts.force = true;
    //             }
    //         }
    //         if (!opts.url and !opts.local) {
    //             opts.url = true;
    //             opts.local = true;
    //         }
    //         cli.options = opts;
    //         try cli.updateFeeds();
    //     } else if (mem.eql(u8, "clean", arg)) {
    //         try cli.cleanItems();
    //     } else if (mem.eql(u8, "search", arg)) {
    //         if (try iter.next(allocator)) |value| {
    //             try cli.search(value);
    //         } else {
    //             log.err("Subcommand search missing term", .{});
    //         }
    //     } else if (mem.eql(u8, "delete", arg)) {
    //         if (try iter.next(allocator)) |value| {
    //             try cli.deleteFeed(value);
    //         } else {
    //             log.err("Subcommand delete missing argument location", .{});
    //         }
    //     } else if (mem.eql(u8, "print", arg)) {
    //         if (try iter.next(allocator)) |value| {
    //             if (mem.eql(u8, "feeds", value)) {
    //                 try cli.printFeeds();
    //                 return;
    //             }
    //         }

    //         try cli.printAllItems();
    //     } else {
    //         log.err("Unknown argument: {s}", .{arg});
    //         return error.UnknownArgument;
    //     }
    // }
}
