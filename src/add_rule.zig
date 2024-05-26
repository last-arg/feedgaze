const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

pub const AddRule = @This();

rules: []Rule = &.{},

pub fn create_rule(match_raw:[]const u8, result_raw: []const u8) !Rule {
    const uri = std.Uri.parse(match_raw) catch return error.InvalidMatchUrl;
    const host = uri.host orelse return error.MissingMatchHost;
    const result_uri = std.Uri.parse(result_raw) catch std.Uri.parseWithoutScheme(result_raw) catch {
        return error.InvalidResultUrl;
    };

    // TODO?: check that match and result placeholders match?
    // Make sure can create result url from match?
    // Does placeholder count for match and result have to be same?

    return .{
      .match_host = host,
      .match_path = uri.path,
      .result_host = result_uri.host orelse host, 
      .result_path = result_uri.path, 
    };
}

pub const RuleWithHost = struct {
    match_path: []const u8,
    result_host: []const u8 = "",
    result_path: []const u8,

    pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("RuleWithHost:\n\tmatch_path: ");
        try writer.writeAll(value.match_path);
        try writer.writeAll("\n\tresult_host: ");
        try writer.writeAll(value.result_host);
        try writer.writeAll("\n\tresult_path: ");
        try writer.writeAll(value.result_path);
    }
};

pub fn find_rule_match(uri: std.Uri, rules: []RuleWithHost) !?RuleWithHost {
    var uri_path_iter = mem.splitScalar(u8, uri_component_val(uri.path), '/');
    outer: for (rules) |rule| {
        uri_path_iter.reset();
        _ = uri_path_iter.next() orelse continue;
        var rule_path_iter = mem.splitScalar(u8, rule.match_path, '/');
        _ = rule_path_iter.next() orelse continue;
        
        while (uri_path_iter.next()) |uri_path_part| {
            if (uri_path_part.len == 0) continue;
            const rule_path_part = rule_path_iter.next() orelse continue :outer;
            assert(rule_path_part.len > 0);
            if (rule_path_part[0] != '*' and !mem.eql(u8, rule_path_part, uri_path_part)) {
                continue :outer;
            }
        }
        return rule;
    }

    return null;
}

pub const Rule = struct {
    match_host: []const u8,
    match_path: []const u8,
    result_host: []const u8 = "",
    result_path: []const u8,

    pub fn format(value: Rule, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("Rule:\n\tmatch_host: ");
        try writer.writeAll(value.match_host);
        try writer.writeAll("\n\tmatch_path: ");
        try writer.writeAll(value.match_path);
        try writer.writeAll("\n\tresult_path: ");
        try writer.writeAll(value.result_path);
    }
};

pub fn find_match(self: AddRule, input: []const u8) !?Rule {
    const uri = try std.Uri.parse(input);
    const host = uri.host orelse return null;
    var rule_matched: ?Rule = null;

    for (self.rules) |rule| {
        if (!std.mem.eql(u8, rule.match.host, host)) {
            continue;
        }
        var rule_seg = mem.splitScalar(u8, rule.match.path, '/');
        var input_seg = mem.splitScalar(u8, uri.path, '/');
        // skip first slash
        _ = rule_seg.next();
        _ = input_seg.next();
        var rule_match = false;

        while (input_seg.next()) |input_part| {
            if (input_part.len == 0) {
                continue;
            }

            if (rule_seg.next()) |rule_part| {
                if (rule_part.len == 0) {
                    break;
                }
                if (rule_part[0] == '*') {
                    if (rule_part.len > 0) {
                        
                    }
                    continue;
                } else if (!mem.eql(u8, input_part, rule_part)) {
                    break;
                }
                rule_match = true;
            } else {
                rule_match = false;
                break;
            }
        }
        if (rule_seg.next() != null) {
            rule_match = false;
        }
        if (rule_match) {
            const last_index = mem.lastIndexOfScalar(u8, rule.result.path, '*') orelse 0;
            const slash_last_index = mem.lastIndexOfScalar(u8, rule.result.path, '/') orelse 0;
            if (last_index > slash_last_index) {
                const needle = rule.result.path[last_index + 1..];
                if (needle.len > 0) {
                    if (mem.endsWith(u8, uri.path, needle)) {
                        continue;
                    }
                }
            }
            rule_matched = rule;
            break;
        }
    }

    // std.debug.print("input: {s}\n", .{input});
    // std.debug.print("{any}\n", .{rule_matched});

    return rule_matched;
}

pub fn transform_rule_match(allocator: mem.Allocator, uri: std.Uri, rule: RuleWithHost) ![]const u8 {
    const path_str = uri_component_val(uri.path);
    var output_arr = try std.ArrayList(u8).initCapacity(allocator, path_str.len);
    defer output_arr.deinit();

    var uri_iter = mem.splitScalar(u8, path_str, '/');
    _ = uri_iter.next();
    var result_iter = mem.splitScalar(u8, rule.result_path, '/');
    _ = result_iter.next();

    while (result_iter.next()) |result| {
        const uri_value = uri_iter.next() orelse continue;
        try output_arr.append('/');
        if (result[0] == '*') {
            try output_arr.appendSlice(uri_value);
            if (result.len > 0) {
                try output_arr.appendSlice(result[1..]);
            }
        } else {
            try output_arr.appendSlice(result);
        }
    }

    var tmp_uri = uri;
    set_uri_component(&tmp_uri.path, output_arr.items);
    return try std.fmt.allocPrint(allocator, "{}", .{tmp_uri});
}

pub fn set_uri_component(uri_comp: *std.Uri.Component, val: []const u8) void {
    switch(uri_comp.*) {
        .raw, .percent_encoded => |*field| field.* = val,
    }
}

pub fn uri_component_val(uri_comp: std.Uri.Component) []const u8 {
    return switch (uri_comp) {
        .raw, .percent_encoded => |val| val,
    };
}

