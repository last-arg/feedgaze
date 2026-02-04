const std = @import("std"); 
const html = @import("./html.zig");
const z = @import("zignal");
const print = std.debug.print;

const IcoType = enum(u16) {
    ico = 1,
    cur = 2,
};

pub fn minify_ico(writer: *std.Io.Writer, src: []const u8) ![]const u8 {
    const reserved = std.mem.readInt(u16, src[0..2], .little);
    if (reserved != 0) {
        return error.InvalidIcoImage;
    }

    const type_raw = std.mem.readInt(u16, src[2..4], .little);
    const count = std.mem.readInt(u16, src[4..6], .little);

    if (count == 1) {
        return src;
    }
    
    const type_enum = try std.meta.intToEnum(IcoType, type_raw);
    if (type_enum == .cur) {
        return error.CurImageUnsupported;
    }

    const img_entries = src[6..6 + count*16];
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

    const img_data = src[icon_offset..icon_offset + icon_size];
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

pub fn main() !void {
    const img = @embedFile("./tmp.ico");

    var buf: [1024 * 1024]u8 = undefined;
    var io = std.Io.Writer.fixed(&buf);
    const v = try minify_ico(&io, img);
    std.debug.print("len: {}\n", .{v.len});
}

const PngColor = z.Rgba;
const PngImage = z.Image(PngColor);
const img_size = 64;
var png_buf: [img_size * img_size]PngColor = undefined;
pub fn resize_png(allocator: std.mem.Allocator, data: []const u8) !PngImage {
    const i = try z.png.loadFromBytes(PngColor, allocator, data, .{});
    std.debug.assert(i.rows > img_size and i.cols > img_size);
    var new = PngImage.empty;
    new.data = &png_buf;
    new.rows = img_size;
    new.cols = img_size;
    new.stride = img_size;
    try i.resize(allocator, new, .lanczos);
    return new;
}


