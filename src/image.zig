const std = @import("std"); 
const html = @import("./html.zig");
const z = @import("zignal");
const print = std.debug.print;
const mem = std.mem;

pub const Type = enum {
    png, // image/png
    jpeg, // image/jpeg
    jpg, // image/jpeg
    webp, // image/webp
    avif, // image/avif
    svg, // image/svg+xml
    ico, // image/x-icon, image/vnd.microsoft.icon

    pub fn from_string(str: []const u8) ?@This() {
        var iter = mem.splitScalar(u8, str, '/');
        _ = iter.next() orelse return null;
        const end = iter.next() orelse return null;
        if (mem.eql(u8, end, "x-icon") or mem.eql(u8, end, "vnd.microsoft.icon")) {
            return .ico;
        } else if (mem.eql(u8, end, "svg+xml")) {
            return .svg;
        } else if (mem.eql(u8, end, "jpg")) {
            return .jpg;
        }
        return std.meta.stringToEnum(@This(), end);
    }

    pub fn from_data(data: []const u8) ?Type {
        if (is_png(data)) {
            return .png;
        } else if (is_jpg(data)) {
            return .jpg;
        } else if (is_webp(data)) {
            return .webp;
        } else if (is_ico(data)) {
            return .ico;
        } else if (is_svg(data)) {
            return .svg;
        } else if (is_avif(data)) {
            return .avif;
        }
         
        return null;
    }

    pub fn to_content_type(self: @This()) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .jpg => "image/jpeg",
            .webp => "image/webp",
            .avif => "image/avif",
            .svg => "image/svg+xml",
            .ico => "image/x-icon",
        };
    }

    pub fn to_string(value: @This()) []const u8 {
        return switch (value) {
            .png => ".png",
            .jpeg => ".jpeg",
            .jpg => ".jpg",
            .webp => ".webp",
            .avif => ".avif",
            .svg => ".svg",
            .ico => ".ico",
        };
    }

    fn is_svg(data: []const u8) bool {
        var haystack = data[0..@min(data.len, 4 * 1024)];
        if (mem.indexOf(u8, haystack, "<?xml")) |idx| {
            haystack = haystack[idx + 5..];
        } else {
            return false;
        }

        return mem.containsAtLeast(u8, haystack, 1, "<svg");
    }

    fn is_png(data: []const u8) bool {
        const png_sig = .{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        return mem.startsWith(u8, data, &png_sig);
    }

    fn is_avif(data: []const u8) bool {
        const sig = .{0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66};
        return mem.startsWith(u8, data[4..], &sig);
    }

    fn is_jpg(data: []const u8) bool {
        const sig_start = .{ 0xFF, 0xD8 };
        const sig_end = .{ 0xFF, 0xD9};

        return mem.startsWith(u8, data, &sig_start)
            or mem.endsWith(u8, data, &sig_end);
    }

    fn is_webp(data: []const u8) bool {
        const sig_from_0 = .{ 0x52, 0x49, 0x46, 0x46 };
        const sig_from_8 = .{ 0x57, 0x45, 0x42, 0x50 };
        return mem.startsWith(u8, data, &sig_from_0)
            or mem.startsWith(u8, data[8..], &sig_from_8);
    }

    fn is_ico(data: []const u8) bool {
        const sig = .{0x00, 0x00, 0x01, 0x00};
        return mem.startsWith(u8, data, &sig);
    }
};

const IcoType = enum(u16) {
    ico = 1,
    cur = 2,
};

pub fn minify_ico(writer: *std.Io.Writer, data: []const u8) ![]const u8 {
    const reserved = std.mem.readInt(u16, data[0..2], .little);
    if (reserved != 0) {
        return error.InvalidIcoImage;
    }

    const type_raw = std.mem.readInt(u16, data[2..4], .little);
    const count = std.mem.readInt(u16, data[4..6], .little);

    if (count == 1) {
        return data;
    }
    
    const type_enum = try std.meta.intToEnum(IcoType, type_raw);
    if (type_enum == .cur) {
        return error.CurImageUnsupported;
    }

    const img_entries = data[6..6 + count*16];
    var icon_curr: html.IconSize = .{};
    var icon_idx: usize = 0;
    var icon_offset: u32 = 0;
    var icon_size: u32 = 0;

    for (0..count) |idx| {
        const start = idx * 16;
        const end = start + 16;
        const entry = img_entries[start..end];
         
        const width_raw: u16 = @intCast(entry[0]);
        if (width_raw < 0 or width_raw > 255) {
            std.log.warn(".ico image entry has invalid width value {d}. Valid value is from 0 - 255", .{width_raw});
            continue;
        }

        const width = if (width_raw == 0) 256 else width_raw;

        const height_raw: u16 = @intCast(entry[1]);
        const height = if (height_raw == 0) 256 else height_raw;
        if (height_raw < 0 or height_raw > 255) {
            std.log.warn(".ico image entry has invalid height value {d}. Valid value is from 0 - 255", .{height_raw});
            continue;
        }

        const reserved_entry = entry[3];
        if (reserved_entry != 0) {
            std.log.warn(".ioc image entry 'reserved' value must be 0. Provided value: {d}", .{reserved});
            continue;
        }

        const image_data_size = std.mem.readInt(u32, entry[8..12], .little);
        const offset = std.mem.readInt(u32, entry[12..16], .little);

        const new_size: html.IconSize = .{
            .width = width,
            .height = height,
        };
        const result_size = icon_curr.pick_icon(new_size);

        if (std.meta.eql(icon_curr, result_size)) {
            continue;
        } else {
            icon_curr = new_size;
            icon_offset = offset;
            icon_size = image_data_size;
            icon_idx = idx;
        }
    }

    const img_data = data[icon_offset..icon_offset + icon_size];
    var w = writer;
    const start_ico = w.buffered().len;
    try w.ensureUnusedCapacity(22 + img_data.len);

    // Write .ico header
    // reserved
    w.writeInt(u16, 0, .little) catch unreachable;
    // type
    w.writeInt(u16, type_raw, .little) catch unreachable;
    // count
    w.writeInt(u16, 1, .little) catch unreachable;

    // Write entry
    const start = icon_idx * 16;
    const end = start + 12;
    const entry_without_offset = img_entries[start..end];
    w.writeAll(entry_without_offset) catch unreachable;
    w.writeInt(u32, 22, .little) catch unreachable;

    // Write image data
    w.writeAll(img_data) catch unreachable;
    try w.flush();

    return w.buffered()[start_ico..];
}

pub const Color = z.Rgba;
pub const Image = z.Image(Color);
const img_size = @import("./app_config.zig").icon_size;
var img_buf: [img_size * img_size]Color = undefined;

pub fn resize_png(allocator: std.mem.Allocator, data: []const u8) !Image {
    const i = try z.png.loadFromBytes(Color, allocator, data, .{});
    if (i.rows <= img_size or i.cols <= img_size) {
        return i;
    }
    std.debug.assert(i.rows > img_size and i.cols > img_size);
    var new = Image.empty;
    new.data = &img_buf;
    new.rows = img_size;
    new.cols = img_size;
    new.stride = img_size;
    try i.resize(allocator, new, .lanczos);
    return new;
}

pub fn resize_jpeg(allocator: std.mem.Allocator, data: []const u8) !Image {
    const i = try z.jpeg.loadFromBytes(Color, allocator, data, .{});
    if (i.rows <= img_size or i.cols <= img_size) {
        return i;
    }
    std.debug.assert(i.rows > img_size and i.cols > img_size);
    var new = Image.empty;
    new.data = &img_buf;
    new.rows = img_size;
    new.cols = img_size;
    new.stride = img_size;
    try i.resize(allocator, new, .lanczos);
    return new;
}

pub fn process(allocator: std.mem.Allocator, data: []const u8, img_type_opt: ?Type) ![]const u8 {
    const img_type_from_data = Type.from_data(data) orelse blk: {
        std.log.warn("Could not figure out image file type based on file content", .{});
        if (img_type_opt) |img_type| {
            std.log.warn("Will use file type {} from HTTP header 'Content-type'", .{img_type});
        }
        break :blk null;
    
    };

    const img_type = img_type_opt orelse img_type_from_data orelse {
        return error.UnknownImageType;
    };

    if (img_type_from_data != img_type) {
        std.log.warn("Image file type and HTTP 'Content-Type' don't match. Using file type from image content", .{});
    }
    
    switch(img_type) {
        .png => {
            var img = try resize_png(allocator, data);
            errdefer img.deinit(allocator);
            if (img.rows <= img_size or img.cols <= img_size) {
                return data;
            }
            return try z.png.encode(Color, allocator, img, .{});
        },
        .jpeg, .jpg => {
            var img = try resize_jpeg(allocator, data);
            errdefer img.deinit(allocator);
            if (img.rows <= img_size or img.cols <= img_size) {
                return data;
            }
            return try z.jpeg.encode(Color, allocator, img, .{});
        },
        .ico => {
            var io_writer: std.Io.Writer.Allocating = try .initCapacity(allocator, 20 * 1024);
            errdefer io_writer.deinit();
            var writer = io_writer.writer;
            const result = try minify_ico(&writer, data);
            return result;
        },
        .avif, .svg, .webp => {
            return data;
        },
    }
}
