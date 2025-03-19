const std = @import("std");

pub fn is_url(url: []const u8) bool {
    return if (std.Uri.parse(url)) |_| true else |_| false;
}

pub fn is_data(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "data:");
}

pub fn is_url_or_data(url: []const u8) bool {
    return is_url(url) or is_data(url);
}

pub fn uri_component_val(uri_comp: std.Uri.Component) []const u8 {
    return switch (uri_comp) {
        .raw, .percent_encoded => |val| val,
    };
}

