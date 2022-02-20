const std = @import("std");
const http = @import("http.zig");
const zuri = @import("zuri");
const zfetch = @import("zfetch");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const assert = std.debug.assert;
const print = std.debug.print;
const log = std.log;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

pub fn urlToLoginName(url: []const u8) !?[]const u8 {
    const uri = try zuri.Uri.parse(url, true);
    if (uri.path.len >= 1) {
        var login_name = uri.path[1..];
        const end_index = mem.indexOf(u8, login_name, "/") orelse login_name.len;
        return login_name[0..end_index];
    }
    return null;
}

test "urlToLoginName()" {
    const expected_login_name = "jackjack4";
    const domain = "twitch.tv";
    {
        const input_url = domain ++ "/" ++ expected_login_name;
        const login_name = try urlToLoginName(input_url);
        try expectEqualStrings(expected_login_name, login_name.?);
    }

    {
        const login_name = try urlToLoginName(domain);
        try expect(null == login_name);
    }
}
