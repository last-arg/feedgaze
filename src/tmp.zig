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
    try superhtml();
}

pub const std_options: std.Options = .{
    // This sets log level based on scope.
    // This overrides global log_level
    .log_scope_levels = &.{ 
        .{.level = .err, .scope = .@"html/tokenizer"},
        .{.level = .err, .scope = .@"html/ast"} 
    },
    // This set global log level
    .log_level = .debug,
};

// html selectors for feed
// title - ?optional. Can be title (hX) or description/text.
// link - required. If no title selector provided take text from link as
// title.

const super = @import("superhtml");

pub fn has_class(node: super.html.Ast.Node, code: []const u8, selector: []const u8) bool {
    var iter = node.startTagIterator(code, .html);
    while (iter.next(code)) |tag| {
        const name = tag.name.slice(code);
        if (!std.ascii.eqlIgnoreCase("class", name)) { continue; }

        if (tag.value) |value| {
            const expected_class_name = selector[1..];
            std.debug.assert(expected_class_name.len > 0);
            var token_iter = std.mem.tokenizeScalar(u8, value.span.slice(code), ' ');
            while (token_iter.next()) |class_name| {
                if (std.ascii.eqlIgnoreCase(expected_class_name, class_name)) {
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn superhtml() !void {
    var gen = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gen.allocator());
    defer arena.deinit();
    const code = 
    \\<!DOCTYPE html>
    \\<html>
    \\ <head>
    \\  <title>Test this</title>
    \\ </head>
    \\ <body>
    \\  <div class="wrapper first">
    \\   <p class="foo bar" id="my-id">hello</p>
    \\  </div>
    \\  <span class="wrapper">
    \\   <p class="foo">world</p>
    \\  </span>
    \\ </body>
    \\</html>
    ;
    const ast = try super.html.Ast.init(arena.allocator(), code, .html);
    const Selector = struct {
        iter: std.mem.SplitBackwardsIterator(u8, .scalar), 

        pub fn init(input: []const u8) @This() {
            return .{
                .iter = std.mem.splitBackwardsScalar(u8, input, ' '),
            };
        }

        pub fn next(self: *@This()) ?[]const u8 {
            while (self.iter.next()) |val| {
                if (val.len == 0) {
                    continue;
                }
                return val;
            }
            return null;
        }
    };
    var selector = Selector.init(".first p");
    const last_selector = selector.next() orelse @panic("there should be CSS selector");
    // const last_selector = "p";
    const is_last_elem_class = last_selector[0] == '.';
    std.debug.assert(
        (is_last_elem_class and last_selector.len > 1)
        or last_selector.len > 0
    );
    var last_matches = try std.ArrayList(super.html.Ast.Node).initCapacity(arena.allocator(), 10);
    defer last_matches.deinit();

    print("==> Find last selector matches\n", .{});
    for (ast.nodes) |node| {
        if (node.kind == .element or node.kind == .element_void or node.kind == .element_self_closing) {
            if (is_last_elem_class) {
                if (has_class(node, code, last_selector)) {
                    try last_matches.append(node);
                }
            } else {
                const span = node.open.getName(code, .html);
                if (std.ascii.eqlIgnoreCase(last_selector, span.slice(code))) {
                    try last_matches.append(node);
                }
            }
        }
        
    }
    print("==> last selector matches: {d}\n", .{last_matches.items.len});

    var selector_matches = try std.ArrayList(super.html.Ast.Node).initCapacity(arena.allocator(), 10);
    defer selector_matches.deinit();

    var selector_value = selector.next();
    const has_multiple_selectors = selector_value == null;

    if (has_multiple_selectors) {
        for (last_matches.items) |last_node| {
            print("start node: |{}|\n", .{last_node});
            var parent_idx = last_node.parent_idx;
            var selector_rest_iter = selector;

            while (parent_idx != 0) {
                std.debug.assert(selector_value != null);
                const node = ast.nodes[parent_idx];
                const span = node.open.getName(code, .html);
                const is_class = selector_value.?[0] == '.';
                if (is_class) {
                    if (has_class(node, code, selector_value.?)) {
                        if (selector_rest_iter.next()) |next| {
                            selector_value = next;
                        } else {
                            // found selector match
                            try selector_matches.append(last_node);
                            break;
                        }
                    }
                } else {
                    if (std.ascii.eqlIgnoreCase(selector_value.?, span.slice(code))) {
                        if (selector_rest_iter.next()) |next| {
                            selector_value = next;
                        } else {
                            // found selector match
                            try selector_matches.append(last_node);
                            break;
                        }
                    }
                }
                print("parent_node {s}\n", .{span.slice(code)});
                parent_idx = node.parent_idx;
            }
        }
    }
    print("==> selector matches: {d}\n", .{selector_matches.items.len});

    const matches = if (has_multiple_selectors) selector_matches else last_matches; 
    print("==> matches: {d}\n", .{matches.items.len});

    // const current = ast.nodes[1];
    // while (true) {
    //     switch (current.kind) {
    //         .root => {
    //             print("root\n", .{});
    //         },
    //         .doctype => {
    //             print("doctype\n", .{});
    //         },
    //         .element => {
    //             print("elem\n", .{});
    //         },
    //         .element_void => {
    //             print("elem_void\n", .{});
    //         },
    //         .element_self_closing => {
    //             print("elem_self_close\n", .{});
    //         },
    //         .comment => {
    //             print("comment\n", .{});
    //         },
    //         .text => {
    //             print("text\n", .{});
    //         },
    //     }
        
    //     break;
    // }

    // _ = ast; // autofix
    if (ast.errors.len > 0) {
        ast.printErrors(code, "<STRING>");
        std.process.exit(1);
    }
    ast.debug(code);
}

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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var storage = try Storage.init("./tmp/feeds.db");
    {
        const feeds = try storage.feed_icons_missing(alloc);
        print("len: {d}\n", .{feeds.len});
    }
    {
        const feeds = try storage.feed_icons_all(alloc);
        print("len: {d}\n", .{feeds.len});
    }
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
