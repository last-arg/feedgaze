const std = @import("std");
const AddRule = @import("add_rule.zig");
const create_rule = AddRule.create_rule;
const Storage = @import("storage.zig").Storage;
const print = std.debug.print;

pub fn main() !void {
    // try run_storage_rule_add();
    // try run_rule_transform();
    try run_add_new_feed();
}

// check if new feed url hits any add_rules
// - if it does transform feed url 
// - if not use url as is
pub fn run_add_new_feed() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator(); 

    var storage = try Storage.init("./tmp/feeds.db");
    const input = "http://github.com/hello";
    const uri = try std.Uri.parse(input);
    const add_rule = try storage.get_add_rule(allocator, uri);
    print("add_rule: {any}\n", .{add_rule});

    const r_1 = try AddRule.transform_rule_match(allocator, uri, add_rule.?);
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
        try create_rule("http://github.com/*/*/commits", "/*/*/commits.atom"),
        try create_rule("http://github.com/*/*", "/*/*/commits.atom"),
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
    const r1 = try create_rule("http://github.com/hello", "/world");
    try storage.rule_add(r1);
    try storage.rule_add(r1);
}
