const std = @import("std");
const zdt = @import("zdt");
const Datetime = zdt.Datetime;
const html = @import("./html.zig");
const image = @import("image.zig");

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

pub fn is_inline_svg(data: []const u8) bool {
    std.debug.assert(!std.ascii.isWhitespace(data[0]));
    return std.mem.startsWith(u8, data, "<svg");
}

pub fn count_date_len(comptime fmt: []const u8, date: Datetime) usize {
    var trash_buffer: [64]u8 = undefined;
    var dw: std.Io.Writer.Discarding = .init(&trash_buffer);
    date.toString(fmt, &dw.writer) catch unreachable;
    return @intCast(dw.count + dw.writer.end);
}

// Date for machine "2011-11-18T14:54:39Z". For <time datetime="...">.
pub const date_len_max = count_date_len(zdt.Formats.RFC3339, Datetime{ .utc_offset = zdt.UTCoffset.UTC, });

pub fn timestampToString(buf: []u8, timestamp: ?i64) []const u8 {
    const ts = timestamp orelse return "";

    var w: std.Io.Writer = .fixed(buf);
    const dt = Datetime.fromUnix(ts, .second, .{.tz = &zdt.Timezone.UTC }) catch return "";
    dt.toString(zdt.Formats.RFC3339, &w) catch |err| {
        std.log.warn("Failed to format date timestamp. Error: {}", .{err});
        return "";
    };

    return w.buffered();
}

pub fn get_icon_from_html(writer: *std.Io.Writer, uri: std.Uri, html_body: []const u8) !?[]const u8 {
    if (html.parse_icon(html_body)) |icon_url| {
        if (is_data(icon_url)) {
            return icon_url; 
        } else {
            writer.end = 0;
            try writer.writeAll(icon_url);
            const page_url_new = try uri.resolveInPlace(icon_url.len, &writer.buffer);
            try std.Uri.Format.default(.{
                .uri = &page_url_new,
                .flags = .all,
            }, writer);

            return writer.buffered()[icon_url.len..];
        }
    }

    return null;
}

pub fn image_raw_from_data_uri(input: []const u8) ?[]const u8 {
    std.debug.assert(is_data(input));
    const meta_start_index = "data:".len;
    const meta_end_index = std.mem.indexOfScalarPos(u8, input, meta_start_index, ',') orelse {
        std.log.warn("Data URI image is invalid. Data: {s}", .{input});
        return null;
    };

    const content_start_index = meta_end_index + 1;
    const content = input[content_start_index..];

    const file_type_end_index = std.mem.indexOfScalarPos(u8, input, meta_start_index, ';') orelse content_start_index;
    const file_type_raw = input[meta_start_index..file_type_end_index];
    const is_file_type_valid = image.Type.from_string(file_type_raw) != null
        or image.Type.from_data(content) != null;

    if (!is_file_type_valid) {
        std.log.warn("Image file type not supported. Got: '{s}'. Valid image file types: image/png, image/jpeg, image/jpeg, image/webp, image/avif, image/svg+xml, image/x-icon, image/vnd.microsoft.icon", .{file_type_raw});
        return null;
    }

    return content;
}
