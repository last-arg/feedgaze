const std = @import("std");
const print = std.debug.print;
const Cli = @import("app.zig").Cli;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    // const allocator = init.gpa;
    const allocator = gpa.allocator();
    const io = init.io;
    {
        const progress_node = std.Progress.start(io, .{});
        defer progress_node.end();

        var buf_writer: [4 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &buf_writer);
        var buf_reader: [4 * 1024]u8 = undefined;
        var in = std.Io.File.stdin().reader(io, &buf_reader);

        var app_cli = Cli{
            .allocator = allocator,
            .io = io,
            .out = &out.interface,
            .in = &in.interface,
            .progress = progress_node,
        };
        try app_cli.run(init);
    }
    const has_leaked = gpa.detectLeaks();
    std.log.debug("Has leaked: {}\n", .{has_leaked});
}

// pub fn main() !void {
//     try longCompileTime();
//     std.debug.print("DONE\n", .{});
// }

// Cause of long compile times? https://github.com/ziglang/zig/issues/15266
// fn longCompileTime() !void {

//     // When I added std.http.Client.request function my compile times increased several fold from
//     // ~1s to ~16s. After looking deeper found that is was caused by std.crypto.tls.Client.init
//     // function. My guess is that is cause by some comptime stuff, probably arrays.
//     {
//         var gen = std.heap.GeneralPurposeAllocator(.{}){};
//         var arena = std.heap.ArenaAllocator.init(gen.allocator());
//         defer arena.deinit();
//         var client = std.http.Client{ .allocator = arena.allocator() };
//         const host = "github.com";
//         const port = 80;
//         const stream = try std.net.tcpConnectToHost(arena.allocator(), host, port);
//         errdefer stream.close();

//         const tls_client = try std.crypto.tls.Client.init(stream, client.ca_bundle, host);
//         _ = tls_client;
//     }

//     // {
//     //     const w: u32 = 1080;
//     //     const h: u32 = 40;

//     //     // time: 1.26 sec
//     //     // var pixels: [w * h * 3]f32 = [1]f32{0.0} ** (w * h * 3);
//     //     // time: 4.26 sec
//     //     // var pixels = std.mem.zeroes([w * h * 3]f32);
//     //     // time: 1.24 sec
//     //     var pixels = comptime std.mem.zeroes([w * h * 3]f32);
//     //     _ = pixels;
//     //     // pixels[69] = 42;
//     // }
// }
