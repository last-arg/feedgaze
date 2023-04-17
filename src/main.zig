const std = @import("std");
// const log = std.log;
// const mem = std.mem;
const print = std.debug.print;
// const process = std.process;
// const Allocator = std.mem.Allocator;
const http = std.http;
// const Cli = @import("app.zig").Cli;

// pub const log_level = std.log.Level.debug;

pub fn main() !void {
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();
    // print("Hello\n", .{});

    // Cause of long compile times? https://github.com/ziglang/zig/issues/15266
    {
        const input = "http://github.com";
        const url = try std.Uri.parse(input);
        var client = http.Client{ .allocator = arena.allocator() };
        defer client.deinit();
        print("bool: {?} and {?s}\n", .{ client, url.host });

        var req = try client.request(url, .{}, .{});
        print("uri: {?s}\n", .{req.uri.host});
    }

    // {
    //     const len = 2 * 100_000;
    //     // const len = 1024;
    //     var a = std.mem.zeroes([len]u8);
    //     a[0] = 1;
    // }

    // {
    // const FeedRequest = @import("./http_client.zig").FeedRequest;
    // const url = try std.Uri.parse(input);
    // var client = Client{ .allocator = arena.allocator() };
    // defer client.deinit();
    // var req = try FeedRequest.init(&client, url, .{});
    // defer req.deinit();
    // }

    // const writer = std.io.getStdOut().writer();
    // const CliApp = Cli(@TypeOf(writer));
    // var app_cli = CliApp{
    //     .allocator = arena.allocator(),
    //     .out = writer,
    // };
    // try app_cli.run();
}
