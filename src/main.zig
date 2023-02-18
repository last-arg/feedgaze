const std = @import("std");
const log = std.log;
const mem = std.mem;
const print = std.debug.print;
const process = std.process;
const Allocator = std.mem.Allocator;
const http = std.http;
const Client = http.Client;

// pub const log_level = std.log.Level.debug;

pub fn main1() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const base_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var client: Client = .{
        .allocator = arena_allocator,
    };
    try client.ca_bundle.rescan(arena_allocator);

    const input = "http://localhost:8282/many-links.html";
    const url = try std.Uri.parse(input);
    var req = try client.request(url, .{}, .{});
    defer req.deinit();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = bw.writer();
    _ = w;

    std.debug.print("{}\n", .{req.response.state});
    var total: usize = 0;
    // NOTE: if there is no '>' symbol found in buf, will skip parsing.
    // Make sure buf is big enough to hold <a> or <link> attributes in buffer.
    var buf: [4 * 100]u8 = undefined;
    var buf_len: usize = 0;
    var amt = try req.readAll(&buf);
    total += amt;

    const header_value = parseHeader(req.response.header_bytes.items);
    print("{?s}\n", .{header_value.content_type});
    print("{?s}\n", .{header_value.last_modified});
    print("{?s}\n", .{header_value.etag});

    var feed_links = try FeedLinkArray.initCapacity(arena_allocator, 3);
    defer feed_links.deinit();

    buf_len = if (mem.lastIndexOfScalar(u8, buf[0..amt], '>')) |last_lne_sign|
        last_lne_sign + @boolToInt(last_lne_sign < amt)
    else
        0;

    const len = if (buf_len == 0) amt else buf_len;
    try parseHtmlForFeedLinks(buf[0..len], &feed_links);
    // TODO: prefill start of buf with characters after last_lne_sign
    if (buf_len != 0) {
        mem.copy(u8, buf[0..], buf[buf_len..]);
        buf_len = amt - buf_len;
    }

    while (true) {
        // std.debug.print("Read start\n", .{});
        amt = try req.readAll(buf[buf_len..]);
        total += amt;
        // std.debug.print("  got {d} bytes (total {d})\n", .{ amt, total });
        if (amt == 0) break;
        const new_len = buf_len + amt;
        buf_len = if (mem.lastIndexOfScalar(u8, buf[0..new_len], '>')) |last_lne_sign|
            last_lne_sign + @boolToInt(last_lne_sign < amt)
        else
            0;
        try parseHtmlForFeedLinks(buf[0..new_len], &feed_links);
        if (buf_len != 0) {
            mem.copy(u8, &buf, buf[buf_len..new_len]);
            buf_len = new_len - buf_len;
        }
        // std.debug.print("{s}\n", .{buf[0..amt]});
        // std.debug.print("Read end\n", .{});
    }

    for (feed_links.items) |link| {
        print("link: {s}\n", .{link.link});
        print("type: {}\n", .{link.type});
        print("title: {?s}\n", .{link.title});
    }

    // std.debug.print("{}\n", .{req.response});

    try bw.flush();

    log.info("END", .{});
}
