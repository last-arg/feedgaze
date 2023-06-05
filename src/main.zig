const std = @import("std");
// const log = std.log;
// const mem = std.mem;
const print = std.debug.print;
// const process = std.process;
// const Allocator = std.mem.Allocator;
const http = std.http;
const Cli = @import("app.zig").Cli;
const FeedRequest = @import("./http_client.zig").FeedRequest;

// pub const log_level = std.log.Level.debug;

pub fn main() !void {
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();

    const writer = std.io.getStdOut().writer();
    const CliApp = Cli(@TypeOf(writer), FeedRequest);
    var app_cli = CliApp{
        .allocator = arena.allocator(),
        .out = writer,
    };
    try app_cli.run();
}

// Cause of long compile times? https://github.com/ziglang/zig/issues/15266
fn longCompileTime() void {
    // {
    //     const input = "http://github.com";
    //     const url = try std.Uri.parse(input);
    //     var client = http.Client{ .allocator = arena.allocator() };
    //     defer client.deinit();
    //     print("bool: {?} and {?s}\n", .{ client, url.host });

    //     var req = try client.request(.GET, url, .{ .allocator = arena.allocator() }, .{});
    //     print("uri: {?s}\n", .{req.uri.host});
    // }

    {
        const len = 2 * 100_000;
        // const len = 1024;
        var a = std.mem.zeroes([len]u8);
        a[0] = 1;
    }
}
