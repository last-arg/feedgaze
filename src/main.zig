const std = @import("std");
const sql = @import("sqlite");
const mem = std.mem;
const process = std.process;
const Allocator = std.mem.Allocator;
const log = std.log;
const command = @import("cli.zig");
const FeedDb = @import("feed_db.zig").FeedDb;
const Cli = command.Cli;
usingnamespace @import("queries.zig");

pub const log_level = std.log.Level.debug;
pub const g = struct {
    pub var max_items_per_feed: usize = 10;
};

pub fn main() anyerror!void {
    const base_allocator = std.heap.page_allocator;
    // const base_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const abs_location = "/media/hdd/code/feed_app/tmp/test.feed_dbconn";
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
                try cli.addFeed(value, writer, reader);
            } else {
                log.err("Subcommand add missing feed location", .{});
            }
        } else if (mem.eql(u8, "update", arg)) {
            const force = blk: {
                // TODO: add flag --local
                // TODO: add flag --url/--net
                // TODO?: if no flag default to --all flag?
                if (iter.next(allocator)) |value_err| {
                    const value = try value_err;
                    break :blk mem.eql(u8, "--all", value);
                }
                break :blk false;
            };
            try cli.updateFeeds(.{ .force = force }, writer);
        } else if (mem.eql(u8, "clean", arg)) {
            try cli.cleanItems(writer);
        } else if (mem.eql(u8, "delete", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                try cli.deleteFeed(value, writer, reader);
            } else {
                log.err("Subcommand delete missing argument location", .{});
            }
        } else if (mem.eql(u8, "print", arg)) {
            if (iter.next(allocator)) |value_err| {
                const value = try value_err;
                if (mem.eql(u8, "feeds", value)) {
                    try cli.printFeeds(writer);
                    return;
                }
            }

            try cli.printAllItems(writer);
        } else {
            log.err("Unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
}
