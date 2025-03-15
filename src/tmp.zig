const std = @import("std");
const AddRule = @import("add_rule.zig");
const create_rule = AddRule.create_rule;
const Storage = @import("storage.zig").Storage;
const print = std.debug.print;
const kf = @import("known-folders");

pub fn main() !void {
    // try run_storage_rule_add();
    // try run_rule_transform();
    // try run_add_new_feed();
    // try run_parse_atom();
    // try test_allocating();
    // try storage_item_interval();
    // try storage_test();
    // try find_dir();
    // try http_head();
    // try zig_http();
    // try tmp_progress();
    try tmp_icon();
    // try tmp_parse_icon();
    // try tmp_parse_html();
    // try tmp_iter_attrs();
}


pub fn tmp_iter_attrs() !void {
    const input =
    // \\value="hello" more=values and='also this' ><span>more</span>
    \\  rel="icon"
    \\  href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>👩‍💻</text></svg>"
    \\/><span>REST </span>
    ;

    const html = @import("html.zig");
    html.iter_attributes(input); 
}

pub fn tmp_parse_html() !void {
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();

    const input = @embedFile("tmp_file");

    const html = @import("html.zig");
    const r = try html.parse_html(arena.allocator(), input); 
    print("r.len: {}\n", .{r.links.len});
    if (r.icon_url) |icon|{
        print("url: {s}\n", .{icon});
    }
}

pub fn tmp_parse_icon() !void {
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();

    const input = @embedFile("tmp_file");

    const html = @import("html.zig");
    const icon = html.parse_icon(input); 
    print("tmp.zig icon_url: {?s}\n", .{icon});
}

pub fn tmp_icon() !void {
    const App = @import("app.zig").App;
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();
    const feed_url = "https://www.youtube.com/channel/UC7M-Wz4zK8oikt6ATcoTwBA";

    const icon_url = App.fetch_icon(arena.allocator(), feed_url, null) catch |err| blk: {
        std.log.warn("Failed to fetch favicon for feed '{s}'. Error: {}", .{feed_url, err});
        break :blk null;
    };
    print("data: |{}|\n", .{icon_url.?.data.len});
    print("url: |{s}|\n", .{icon_url.?.url});
}


pub fn tmp_progress() !void {
    const progress_node = std.Progress.start(.{
        .estimated_total_items = 9,
        .root_name = "Updating feeds",
    });
    defer {
        const total_opt = progress_node.index.unwrap();  
        progress_node.end();
        if (total_opt) |total| {
            std.log.info("Feed update [{}/{}]", .{total, 9});
        }
        std.io.getStdOut().writer().writeAll("Update done\n") catch {};
    }

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        progress_node.setCompletedItems(i);
        if (i == 4) {
            std.Progress.lockStdErr();
            try std.io.getStdErr().writer().writeAll("Error happened\n");
            defer std.Progress.unlockStdErr();
        }
        std.time.sleep(std.time.ns_per_s * 0.5);
    }
}


// pub const std_options: std.Options = .{
//     // This sets log level based on scope.
//     // This overrides global log_level
//     .log_scope_levels = &.{ 
//         .{.level = .err, .scope = .@"html/tokenizer"},
//         .{.level = .err, .scope = .@"html/ast"} 
//     },
//     // This set global log level
//     .log_level = .debug,
// };

// html selectors for feed
// title - ?optional. Can be title (hX) or description/text.
// link - required. If no title selector provided take text from link as
// title.


// pub const std_options: std.Options = .{
//     .http_disable_tls = true,
// };

pub fn zig_http() !void {
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();
    const input = "https://github.com";
    const url = try std.Uri.parse(input);
    var client = std.http.Client{ .allocator = arena.allocator() };
    defer client.deinit();
    var s = std.ArrayList(u8).init(arena.allocator());
    var buf: [5 * 1024]u8 = undefined;

    const opts: std.http.Client.FetchOptions = .{ 
        .server_header_buffer = &buf,
        .method = .GET, .location = .{ .uri = url },
        .response_storage = .{ .dynamic = &s},
    };
    const resp = try client.fetch(opts);
    print("headers: |{?s}|\n", .{opts.server_header_buffer});
    print("headers: |{any}|\n", .{opts.headers.host});
    print("host: {d}\n", .{opts.response_storage.dynamic.items.len});
    print("host: {d}\n", .{resp.status});
}

pub fn http_head() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // var storage = try Storage.init("./tmp/feeds.db");
    // const icons = try storage.feed_icons_all(arena.allocator());
    const icons = [_]Storage.FeedIcon{
        .{.feed_id = 99999, .page_url = "http://www.foundmyfitness.com/"}
    };

    // '/favicon.ico'
    // debug: total: 277
    // debug: found: 59
    // debug: duplicate: 135
    // debug: skipped (no page_url): 1

    // '/favicon.png'
    // debug: total: 277
    // debug: found: 12
    // debug: skipped (no page_url): 1

    // '/favicon.ico' + '/favicon.png'
    // debug: total: 277
    // debug: found: 63
    // debug: duplicate: 135
    // debug: skipped (no page_url): 1    
    
    var map = std.StringArrayHashMap([]const u8).init(arena.allocator());
    defer map.deinit();
    var found: usize = 0;
    var duplicate: usize = 0;
    for (icons[0..1]) |icon| {
        const types = @import("feed_types.zig");
        const url = icon.page_url;
        std.log.debug("url: {s}", .{url});
        const uri = std.Uri.parse(std.mem.trim(u8, url, &std.ascii.whitespace)) catch |err| {
            std.log.debug("invalid url: '{s}'", .{url});
            return err;
        };
        const url_root = try std.fmt.allocPrint(arena.allocator(), "{;+}", .{uri});
        if (map.get(url_root)) |value| {
            if (value.len > 0) {
                duplicate += 1;
            }
            continue;
        }

        const icon_path = "/favicon.ico";
        const u = try types.url_create(arena.allocator(), icon_path, uri);
        const http_client = @import("http_client.zig");
        var req = try http_client.init(arena.allocator());
        defer req.deinit();
        if (try http_client.check_icon_path(&req, u)) {
            try map.put(url_root, icon_path);
            found += 1;
            break;
        } else {
            try map.put(url_root, "");
        }
    }
    std.log.debug("total: {}", .{icons.len});
    std.log.debug("found: {}", .{found});
    std.log.debug("duplicate: {}", .{duplicate});
}

pub fn find_dir() !void {
    var buf: [8 * 1024]u8 = undefined;
    var fixed_alloc = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fixed_alloc.allocator();

    const data_dir = try kf.getPath(alloc, .data) orelse unreachable;
    const file_path = try std.fs.path.join(alloc, &.{data_dir, "feedgaze",  "feedgaze.sqlite"});

    print("{s}\n", .{file_path});
}

pub fn storage_test() !void {
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    var storage = try Storage.init("./tmp/feeds.db");
    try storage.upsertIcon(.{
        .url = "https://www.youtube.com/channel/UC7M-Wz4zK8oikt6ATcoTwBA",
        .data = "<data>1",
    });
}

pub fn storage_item_interval() !void {
    var storage = try Storage.init("./tmp/feeds.db");
    try storage.update_item_interval(1);
}

// Trying to see how freeing slice works. Want to know if I can free part 
// of allocated slice. Doesn't seem to be possible.
pub fn test_allocating() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const has_leaked = gpa.detectLeaks();
        std.log.debug("Has leaked: {}\n", .{has_leaked});
    }

    const alloc = gpa.allocator();
    var arr = try alloc.alloc(u8, 2);
    arr[0] = 0;
    arr[1] = 1;
    
    // const n = arr[1..];
    print("arr[0]: {d}\n", .{arr[0]});
    print("arr[1]: {d}\n", .{arr[1]});
    alloc.free(arr[0..]);
    // print("n: {any}\n", .{n});
    // alloc.destroy(&arr[0]);
    // alloc.destroy(&arr[1]);

}

fn run_parse_atom() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = @embedFile("tmp_file"); 
    const feed = try @import("app_parse.zig").parseAtom(alloc, content);
    print("\nSTART {d}\n", .{feed.items.len});
    // for (feed.items) |item| {
    //     print("title: |{s}|\n", .{item.title});
    //     print("link: |{?s}|\n", .{item.link});
    //     // print("date: {?d}\n", .{item.updated_timestamp});
    //     print("\n", .{});
    // }
}


// check if new feed url hits any add_rules
// - if it does transform feed url 
// - if not use url as is
pub fn run_add_new_feed() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator(); 

    var storage = try Storage.init("./tmp/feeds.db");
    const input = "https://github.com/letoram/arcan/commits/master";
    print("\ninput url: {s}\n", .{input});

    const uri = try std.Uri.parse(input);

    const host_str = switch(uri.host.?) { .raw, .percent_encoded => |val| val };
    const rules = try storage.get_rules_for_host(allocator, host_str);
    const rule_with_host = try AddRule.find_rule_match(uri, rules);
    print("rule_with_host: {any}\n", .{rule_with_host});

    const r_1 = try AddRule.transform_rule_match(allocator, uri, rule_with_host.?);
    print("r_1: {s}\n", .{r_1});

    // const rule_match = AddRule.Rule.Match.create(input);
}

// from add_rule.zig
pub fn run_rule_transform() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator(); 

    const url_1 = "https://github.com/letoram/arcan/commits/master";
    const url_2 = "https://github.com/11ty/webc/commits";
    var rules = [_]AddRule.Rule{
        try create_rule("http://github.com/hello", "/world"),
        try create_rule("http://github.com/*/*", "/*/*/commits.atom"),
        try create_rule("http://github.com/*/*/commits", "/*/*/commits.atom"),
        try create_rule("http://github.com/*/*/commits/*", "/*/*/commits/*.atom"),
    };
    const rule = AddRule{ .rules = &rules };
    const r_1 = try rule.transform_match(allocator, "https://github.com/hello");
    std.debug.print("r_1: {s}\n", .{r_1});
    _ = rule.transform_match(allocator, "https://github.com/letoram/arcan/commits/master.atom") catch {};
    const r_3 = try rule.transform_match(allocator, url_1);
    std.debug.print("r_3: {s}\n", .{r_3});
    const r_4 = try rule.transform_match(allocator, url_2);
    std.debug.print("r_4: {s}\n", .{r_4});
}

// from storage.zig
pub fn run_storage_rule_add() !void {
    // var storage = try Storage.init(null);
    var storage = try Storage.init("./tmp/feeds.db");
    const r1 = try create_rule("https://github.com/*/*/commits", "/*/*/commits.atom");
    const r2 = try create_rule("https://github.com/*/*/commits/*", "/*/*/commits/*.atom");

    try storage.rule_add(r1);
    try storage.rule_add(r2);
}
