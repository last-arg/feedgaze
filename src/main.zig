const std = @import("std");
const print = std.debug.print;
const Cli = @import("app.zig").Cli;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    {
        var buf_writer: [4 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &buf_writer);
        var buf_reader: [4 * 1024]u8 = undefined;
        var in = std.Io.File.stdin().reader(io, &buf_reader);

        var app_cli = Cli{
            .allocator = allocator,
            .io = io,
            .out = &out.interface,
            .in = &in.interface,
            .core_count = try std.Thread.getCpuCount(),
        };
        try app_cli.run(init);
    }
}

test {
    const types = @import("feed_types.zig");
    _ = types;
    const storage = @import("storage.zig");
    _ = storage.Storage;
    const parse = @import("feed_parse.zig");
    _ = parse;
}
