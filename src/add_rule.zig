const std = @import("std");
const mem = std.mem;

// TODO: cli, web test rules

const AddRule = struct {
    const Self = @This();
    rules: []Rule = &.{},


    const Rule = struct {
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
            try writer.writeAll("\n");
        }
    };
    
    pub fn find_match(self: Self, input: []const u8) !?Rule {
        const uri = try std.Uri.parse(input);
        std.debug.print("input: {s}\n", .{input});
        var rule_matched: ?Rule = null;

        for (self.rules) |rule| {
            const host = uri.host orelse continue;
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
                rule_matched = rule;
                break;
            }
        }

        std.debug.print("{any}\n", .{rule_matched});

        return rule_matched;
    }

    pub fn transform_match(rule: Rule) !void {
        _ = rule;
        // TODO: Transform input url
    }
};

test "tmp" {
    const expect = std.testing.expect;

    const url_1 = "https://github.com/letoram/arcan/commits/master";
    const url_2 = "https://github.com/11ty/webc/commits";
    var rules = [_]AddRule.Rule{
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
    _ = try rule.find_match(url_1);
    _ = try rule.find_match(url_2);
    try expect(true);
}
