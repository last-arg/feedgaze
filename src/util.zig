const std = @import("std");

pub fn is_url(url: []const u8) bool {
    return if (std.Uri.parse(url)) |_| true else |_| false;
}


