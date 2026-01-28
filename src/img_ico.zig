const std = @import("std"); 
const html = @import("./html.zig");

// TODO: Instead of trying to take image data out of .ico.
// Maybe just make new ico with image data
const IcoType = enum(u16) {
    ico = 1,
    cur = 2,
};

pub fn main() !void {
    const img = @embedFile("./tmp.ico");

    const reserved = std.mem.readInt(u16, img[0..2], .little);
    std.debug.assert(reserved == 0);
    const type_raw = std.mem.readInt(u16, img[2..4], .little);
    const count = std.mem.readInt(u16, img[4..6], .little);
    const type_enum = try std.meta.intToEnum(IcoType, type_raw);
    if (type_enum == .cur) @panic("CUR image not supported");

    std.debug.print("reserved: {d}\n", .{reserved});
    std.debug.print("type: {}\n", .{type_enum});
    std.debug.print("count: {d}\n", .{count});

    std.debug.print("----------------\n", .{});

    const img_entries = img[6..6 + count*16];
    std.debug.print("entries_count: {d}\n", .{6 + count * 16});
    var icon_curr: html.IconSize = .{};
    var icon_idx: usize = 0;
    var icon_offset: u32 = 0;
    var icon_size: u32 = 0;

    for (0..count) |idx| {
        const start = idx * 16;
        const end = start + 16;
        const entry = img_entries[start..end];
        std.debug.print("ENTRY {d}\n", .{idx});
         
        const width_raw: u16 = @intCast(entry[0]);
        std.debug.assert(width_raw >= 0 and width_raw <= 255);
        const width = if (width_raw == 0) 256 else width_raw;
        const height_raw: u16 = @intCast(entry[1]);
        const height = if (height_raw == 0) 256 else height_raw;
        std.debug.assert(height_raw >= 0 and height_raw <= 255);

        const color_count = entry[2];
        std.debug.assert(color_count >= 0 and color_count <= 255);

        const reserved_entry = entry[3];
        std.debug.assert(reserved_entry == 0);

        // Applies only for ICO format
        // Can be larger than 1.
        // Then color_depth = color_planes * bits_per_pixel.
        const color_planes = std.mem.readInt(u16, entry[4..6], .little);
        std.debug.assert(color_planes == 0 or color_planes == 1);

        // Bits per pixel is for ICO format
        const bits_per_pixel = std.mem.readInt(u16, entry[6..8], .little);

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

        std.debug.print("  width: {d}\n", .{width});
        std.debug.print("  height: {d}\n", .{height});
        std.debug.print("  color_count: {d}\n", .{color_count});
        std.debug.print("  color_planes: {d}\n", .{color_planes});
        std.debug.print("  bits_per_pixel: {d}\n", .{bits_per_pixel});
        std.debug.print("  image_data_size: {d}\n", .{image_data_size});
        std.debug.print("  offset: {d}\n", .{offset});
    }

    std.debug.print("RESULT\n", .{});
    std.debug.print("  width: {d}\n", .{icon_curr.width});
    std.debug.print("  height: {d}\n", .{icon_curr.height});

    var f = try std.fs.cwd().createFile("tmp_new.ico", .{
        .read = false,
        // .truncate = true,
        // .exclusive = true,
        // .mode = 0o777,
        .lock = .exclusive,
    });
    defer f.close();
    var buf: [8 * 1024]u8 = undefined;
    var f_writer = f.writer(&buf);
    var w = &f_writer.interface;

    // Write .ico header
    // reserved
    try w.writeInt(u16, 0, .little);
    // type
    try w.writeInt(u16, type_raw, .little);
    // count
    try w.writeInt(u16, 1, .little);

    // Write entry
    const start = icon_idx * 16;
    const end = start + 12;
    const entry_without_offset = img_entries[start..end];
    try w.writeAll(entry_without_offset);
    try w.writeInt(u32, 22, .little);
    try w.writeAll(img[icon_offset..icon_offset + icon_size]);
    try w.flush();
}
