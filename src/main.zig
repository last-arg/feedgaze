const std = @import("std");
const log = std.log;
const sql = @import("sqlite");
const mem = std.mem;
const process = std.process;
const Allocator = std.mem.Allocator;
const command = @import("cli.zig");
const FeedDb = @import("feed_db.zig").FeedDb;
const Cli = command.Cli;

pub const log_level = std.log.Level.debug;

// pub fn main() anyerror!void {
//     log.info("Workds", .{});
// }

pub fn main() anyerror!void {
    const base_allocator = std.heap.page_allocator;
    // const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    log.info("test", .{});

    const abs_location = "/media/hdd/code/feed_app/tmp/test.db_conn";
    // TODO: make default location somewhere in home directory
    // const abs_location = try makeFilePath(allocator, default_feed_dblocation);
    // const feed_dbfile = try std.fs.createFileAbsolute(
    //     abs_location,
    //     .{ .read = true, .truncate = false },
    // );

    var feed_db = try FeedDb.init(allocator, abs_location);

    var iter = process.args();
    _ = iter.skip();

    var writer = std.io.getStdOut().writer();
    const reader = std.io.getStdIn().reader();
    // var cli = Cli{
    //     .allocator = allocator,
    //     .feed_db = &feed_db,
    //     .writer = writer,
    // };
    var cli = command.makeCli(allocator, &feed_db, writer, reader);

    while (iter.next(allocator)) |arg_err| {
        const arg = try arg_err;
        if (mem.eql(u8, "add", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try cli.addFeed(value);
            } else {
                log.err("Subcommand add missing feed location", .{});
            }
        } else if (mem.eql(u8, "update", arg)) {
            var opts = command.UpdateOptions{};
            while (iter.next(allocator)) |value_err| {
                const value = try value_err;
                if (mem.eql(u8, "--all", value)) {
                    opts.url = true;
                    opts.local = true;
                } else if (mem.eql(u8, "--url", value)) {
                    opts.local = false;
                } else if (mem.eql(u8, "--local", value)) {
                    opts.url = false;
                } else if (mem.eql(u8, "--force", value)) {
                    opts.force = true;
                }
            }
            try cli.updateFeeds(opts);
        } else if (mem.eql(u8, "clean", arg)) {
            try cli.cleanItems();
        } else if (mem.eql(u8, "search", arg)) {
            if (iter.next(allocator)) |value_err| {
                const term = try value_err;
                try cli.search(term);
            } else {
                log.err("Subcommand search missing term", .{});
            }
        } else if (mem.eql(u8, "delete", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try cli.deleteFeed(value);
            } else {
                log.err("Subcommand delete missing argument location", .{});
            }
        } else if (mem.eql(u8, "print", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                if (mem.eql(u8, "feeds", value)) {
                    try cli.printFeeds();
                    return;
                }
            }

            try cli.printAllItems();
        } else {
            log.err("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
}
