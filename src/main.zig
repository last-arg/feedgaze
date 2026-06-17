const std = @import("std");
const print = std.debug.print;
const Cli = @import("app.zig").Cli;

pub const std_options: std.Options = .{
    .log_level = .info,
};

// pub fn main() !void {
//     {
//         const dt = @import("tempora");
//         const i = "2011-11-12";
//         const v = try dt.Date.from_string("YYYY-MM", i);
//         print("V: {}\n", .{v});
//     }

//     {
//         const dt = @import("zdt");
//         const i = "2011-11-10";
//         const v = try dt.Datetime.fromString(i, "%Y-%m-%d");
//         print("V: {}\n", .{v});
//     }
// }

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

test {
    const types = @import("feed_types.zig");
    _ = types;
}
