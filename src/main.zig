const std = @import("std");
const log = std.log;
const sql = @import("sqlite");
const mem = std.mem;
const process = std.process;
const Allocator = std.mem.Allocator;
const command = @import("cli.zig");
const Storage = @import("feed_db.zig").Storage;
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

    const abs_location = "/media/hdd/code/feedgaze/tmp/test.db_conn";
    // TODO: make default location somewhere in home directory
    // const abs_location = try makeFilePath(allocator, default_feed_dblocation);
    // const feed_dbfile = try std.fs.createFileAbsolute(
    //     abs_location,
    //     .{ .read = true, .truncate = false },
    // );

    var feed_db = try Storage.init(allocator, abs_location);
    var writer = std.io.getStdOut().writer();
    const reader = std.io.getStdIn().reader();
    var cli = command.makeCli(allocator, &feed_db, writer, reader);

    var iter = process.args();
    _ = iter.skip();
    while (try iter.next(allocator)) |arg| {
        if (mem.eql(u8, "add", arg)) {
            if (try iter.next(allocator)) |value| {
                try cli.addFeed(value);
            } else {
                log.err("Subcommand add missing feed (url or file) location", .{});
            }
        } else if (mem.eql(u8, "update", arg)) {
            var opts = command.CliOptions{ .url = false, .local = false };
            while (try iter.next(allocator)) |value| {
                if (mem.eql(u8, "--url", value)) {
                    opts.url = true;
                } else if (mem.eql(u8, "--local", value)) {
                    opts.local = true;
                } else if (mem.eql(u8, "--force", value)) {
                    opts.force = true;
                }
            }
            if (!opts.url and !opts.local) {
                opts.url = true;
                opts.local = true;
            }
            cli.options = opts;
            try cli.updateFeeds();
        } else if (mem.eql(u8, "clean", arg)) {
            try cli.cleanItems();
        } else if (mem.eql(u8, "search", arg)) {
            if (try iter.next(allocator)) |value| {
                try cli.search(value);
            } else {
                log.err("Subcommand search missing term", .{});
            }
        } else if (mem.eql(u8, "delete", arg)) {
            if (try iter.next(allocator)) |value| {
                try cli.deleteFeed(value);
            } else {
                log.err("Subcommand delete missing argument location", .{});
            }
        } else if (mem.eql(u8, "print", arg)) {
            if (try iter.next(allocator)) |value| {
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
