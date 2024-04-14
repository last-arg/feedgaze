const std = @import("std");
const mem = std.mem;

// TODO: cli, web test rules

pub const AddRule = struct {
    const Self = @This();
    rules: []Rule = &.{},

    pub const Rule = struct {
        const Match = struct {
            host: []const u8,
            path: []const u8,
        };
        const Result = struct {
            path: []const u8,
        };
        match: Match,
        result: Result,

        pub fn format(value: Rule, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.writeAll("Rule.Match:\n\thost: ");
            try writer.writeAll(value.match.host);
            try writer.writeAll("\n\tpath: ");
            try writer.writeAll(value.match.path);
            try writer.writeAll("\n");

            try writer.writeAll("Rule.Result:\n\tpath: ");
            try writer.writeAll(value.result.path);
        }
    };
    
    pub fn find_match(self: Self, input: []const u8) !?Rule {
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

    pub fn transform_match(self: Self, allocator: mem.Allocator, input: []const u8) ![]const u8 {
        const rule_match_opt = try self.find_match(input);
        const rule_match = rule_match_opt orelse return error.NoRuleMatch;
        var uri = try std.Uri.parse(input);

        var output_arr = try std.ArrayList(u8).initCapacity(allocator, uri.path.len);
        defer output_arr.deinit();

        var uri_iter = mem.splitScalar(u8, uri.path, '/');
        _ = uri_iter.next();
        var result_iter = mem.splitScalar(u8, rule_match.result.path, '/');
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

        uri.path = output_arr.items;
        return try std.fmt.allocPrint(allocator, "{}", .{uri});
    }
};

test "tmp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator(); 

    const url_1 = "https://github.com/letoram/arcan/commits/master";
    const url_2 = "https://github.com/11ty/webc/commits";
    var rules = [_]AddRule.Rule{
        .{
            .match = .{.host = "github.com", .path = "/hello"},
            .result = .{.path = "/world"},
        },
        .{
            .match = .{.host = "github.com", .path = "/*/*/commits"},
            .result = .{.path = "/*/*/commits.atom"},
        },
        .{
            .match = .{.host = "github.com", .path = "/*/*"},
            .result = .{.path = "/*/*/commits.atom"},
        },
        .{
            .match = .{.host = "github.com", .path = "/*/*/commits/*"},
            .result = .{.path = "/*/*/commits/*.atom"},
        },
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
