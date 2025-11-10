const std = @import("std");
const datetime = @import("zig-datetime").datetime;
const Datetime = datetime.Datetime;

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

pub fn is_svg(data: []const u8) bool {
    std.debug.assert(!std.ascii.isWhitespace(data[0]));
    return std.mem.startsWith(u8, data, "<svg");
}

// Date for machine "2011-11-18T14:54:39.929Z". For <time datetime="...">.
pub const date_fmt = "{[year]d}-{[month]d:0>2}-{[day]d:0>2}T{[hour]d:0>2}:{[minute]d:0>2}:{[second]d:0>2}.000Z";
pub const date_len_max = std.fmt.count(date_fmt, .{
    .year = 2222,
    .month = 3,
    .day = 2,
    .hour = 2,
    .minute = 2,
    .second = 2,
});

pub fn timestampToString(buf: []u8, timestamp: ?i64) []const u8 {
    if (timestamp) |ts| {
        const dt = Datetime.fromSeconds(@floatFromInt(ts));
        const date_args = .{
            .year = dt.date.year,
            .month = dt.date.month,
            .day = dt.date.day,
            .hour = dt.time.hour,
            .minute = dt.time.minute,
            .second = dt.time.second,
        };
        return std.fmt.bufPrint(buf, date_fmt, date_args) catch unreachable; 
    }

    return "";
}
