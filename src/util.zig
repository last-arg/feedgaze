const std = @import("std");

pub fn is_url(url: []const u8) bool {
    return if (std.Uri.parse(url)) |_| true else |_| false;
}

pub fn uri_component_val(uri_comp: std.Uri.Component) []const u8 {
    return switch (uri_comp) {
        .raw, .percent_encoded => |val| val,
    };
}

