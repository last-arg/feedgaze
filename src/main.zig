const std = @import("std");
const log = std.log;
const mem = std.mem;
const print = std.debug.print;
const process = std.process;
const Allocator = std.mem.Allocator;
const http = std.http;
const Cli = @import("app.zig").Cli;

// pub const log_level = std.log.Level.debug;

pub fn main() !void {
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();
    const writer = std.io.getStdOut().writer();
    const CliApp = Cli(@TypeOf(writer));
    var app_cli = CliApp{
        .allocator = arena.allocator(),
        .out = writer,
    };
    try app_cli.run();
}
