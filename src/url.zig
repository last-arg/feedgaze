const std = @import("std");
const Uri = @import("zuri").Uri;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;

pub fn makeValidUrl(allocator: Allocator, url: []const u8) ![]const u8 {
    const no_http = !std.ascii.startsWithIgnoreCase(url, "http");
    const substr = "://";
    const start = if (std.ascii.indexOfIgnoreCase(url, substr)) |idx| idx + substr.len else 0;
    const no_slash = std.mem.indexOfScalar(u8, url[start..], '/') == null;
    if (no_http and no_slash) {
        return try fmt.allocPrint(allocator, "http://{s}/", .{url});
    } else if (no_http) {
        return try fmt.allocPrint(allocator, "http://{s}", .{url});
    } else if (no_slash) {
        return try fmt.allocPrint(allocator, "{s}/", .{url});
    }
    return try fmt.allocPrint(allocator, "{s}", .{url});
}

test "makeValidUrl()" {
    const allocator = std.testing.allocator;
    const urls = .{ "google.com", "google.com/", "http://google.com", "http://google.com/" };
    inline for (urls) |url| {
        const new_url = try makeValidUrl(allocator, url);
        defer if (!std.mem.eql(u8, url, new_url)) allocator.free(new_url);
        try std.testing.expectEqualStrings("http://google.com/", new_url);
    }
}

pub fn makeWholeUrl(allocator: Allocator, uri: Uri, link: []const u8) ![]const u8 {
    if (link[0] == '/') {
        if (uri.port) |port| {
            if (port != 443 and port != 80) {
                return try fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ uri.scheme, uri.host.name, uri.port, link });
            }
        }
        return try fmt.allocPrint(allocator, "{s}://{s}{s}", .{ uri.scheme, uri.host.name, link });
    }
    return try fmt.allocPrint(allocator, "{s}", .{link});
}
