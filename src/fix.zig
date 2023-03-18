const std = @import("std");
const http = std.http;
const print = std.debug.print;
const Request = http.Client.Request;
const ReadError = Request.ReadError;
const ReaderRaw = Request.ReaderRaw;
const assert = std.debug.assert;
const Uri = std.Uri;
const Client = http.Client;
const mem = std.mem;

pub fn read(req: *Request, buffer: []u8) ReadError!usize {
    while (true) {
        if (!req.response.state.isContent()) {
            try waitForCompleteHead(req);
        }

        if (req.handle_redirects and req.response.headers.status.class() == .redirect) {
            assert(try req.readRaw(buffer) == 0);

            if (req.redirects_left == 0) return error.TooManyHttpRedirects;

            const location = req.response.headers.location orelse
                return error.HttpRedirectMissingLocation;
            const new_url = Uri.parse(location) catch try Uri.parseWithoutScheme(location);

            var new_arena = std.heap.ArenaAllocator.init(req.client.allocator);
            const resolved_url = try req.uri.resolve(new_url, false, new_arena.allocator());
            errdefer new_arena.deinit();

            req.arena.deinit();
            req.arena = new_arena;

            const new_req = try req.client.request(resolved_url, .{}, .{
                .max_redirects = req.redirects_left - 1,
                .header_strategy = if (req.response.header_bytes_owned) .{
                    .dynamic = req.response.max_header_bytes,
                } else .{
                    .static = req.response.header_bytes.unusedCapacitySlice(),
                },
            });
            req.deinit();
            req.* = new_req;
        } else {
            break;
        }
    }

    if (req.response.compression == .none) {
        if (req.response.headers.transfer_compression) |compression| {
            switch (compression) {
                .compress => return error.CompressionNotSupported,
                .deflate => req.response.compression = .{
                    .deflate = try std.compress.zlib.zlibStream(req.client.allocator, ReaderRaw{ .context = req }),
                },
                .gzip => req.response.compression = .{
                    .gzip = try std.compress.gzip.decompress(req.client.allocator, ReaderRaw{ .context = req }),
                },
                .zstd => req.response.compression = .{
                    .zstd = std.compress.zstd.decompressStream(req.client.allocator, ReaderRaw{ .context = req }),
                },
            }
        }
    }

    return switch (req.response.compression) {
        .deflate => |*deflate| try deflate.read(buffer),
        .gzip => |*gzip| try gzip.read(buffer),
        .zstd => |*zstd| try zstd.read(buffer),
        else => try req.readRaw(buffer),
    };
}

const read_buffer_size = 8192;
const ReadBufferIndex = std.math.IntFittingRange(0, read_buffer_size);
fn checkForCompleteHead(req: *Request, buffer: []u8) !usize {
    switch (req.response.state) {
        .invalid => unreachable,
        .start, .seen_r, .seen_rn, .seen_rnr => {},
        else => return 0, // No more headers to read.
    }

    const i = req.response.findHeadersEnd(buffer[0..]);
    if (req.response.state == .invalid) return error.HttpHeadersInvalid;

    const headers_data = buffer[0..i];
    if (req.response.header_bytes.items.len + headers_data.len > req.response.max_header_bytes) {
        return error.HttpHeadersExceededSizeLimit;
    }
    try req.response.header_bytes.appendSlice(req.client.allocator, headers_data);

    if (req.response.state == .finished) {
        print("redirect head: |{s}|\n", .{req.response.header_bytes.items});
        req.response.headers = try Headers.parse(req.response.header_bytes.items);

        if (req.response.headers.upgrade) |_| {
            req.connection.data.closing = false;
            req.response.done = true;
            return i;
        }

        if (req.response.headers.connection == .keep_alive) {
            req.connection.data.closing = false;
        } else {
            req.connection.data.closing = true;
        }

        if (req.response.headers.transfer_encoding) |transfer_encoding| {
            switch (transfer_encoding) {
                .chunked => {
                    req.response.next_chunk_length = 0;
                    req.response.state = .chunk_size;
                },
            }
        } else if (req.response.headers.content_length) |content_length| {
            req.response.next_chunk_length = content_length;

            if (content_length == 0) req.response.done = true;
        } else {
            req.response.done = true;
        }

        return i;
    }

    return 0;
}

pub fn waitForCompleteHead(req: *Request) Request.WaitForCompleteHeadError!void {
    if (req.response.state.isContent()) return;

    while (true) {
        const nread = try req.connection.data.read(req.read_buffer[0..]);
        const amt = try checkForCompleteHead(req, req.read_buffer[0..nread]);

        if (amt != 0) {
            req.read_buffer_start = @intCast(ReadBufferIndex, amt);
            req.read_buffer_len = @intCast(ReadBufferIndex, nread);
            return;
        } else if (nread == 0) {
            return error.UnexpectedEndOfStream;
        }
    }
}

// FIX from std lib
const Headers = struct {
    status: http.Status,
    version: http.Version,
    location: ?[]const u8 = null,
    content_length: ?u64 = null,
    transfer_encoding: ?http.TransferEncoding = null,
    transfer_compression: ?http.ContentEncoding = null,
    connection: http.Connection = .close,
    upgrade: ?[]const u8 = null,

    number_of_headers: usize = 0,

    inline fn int64(array: *const [8]u8) u64 {
        return @bitCast(u64, array.*);
    }

    fn parseInt3(nnn: @Vector(3, u8)) u10 {
        const zero: @Vector(3, u8) = .{ '0', '0', '0' };
        const mmm: @Vector(3, u10) = .{ 100, 10, 1 };
        return @reduce(.Add, @as(@Vector(3, u10), nnn -% zero) *% mmm);
    }

    pub fn parse(bytes: []const u8) !Client.Response.Headers {
        var it = mem.split(u8, bytes[0 .. bytes.len - 4], "\r\n");

        const first_line = it.first();
        if (first_line.len < 12)
            return error.ShortHttpStatusLine;

        const version: http.Version = switch (int64(first_line[0..8])) {
            int64("HTTP/1.0") => .@"HTTP/1.0",
            int64("HTTP/1.1") => .@"HTTP/1.1",
            else => return error.BadHttpVersion,
        };
        if (first_line[8] != ' ') return error.HttpHeadersInvalid;
        const status = @intToEnum(http.Status, parseInt3(first_line[9..12].*));

        var headers: Client.Response.Headers = .{
            .version = version,
            .status = status,
        };

        while (it.next()) |line| {
            headers.number_of_headers += 1;

            if (line.len == 0) return error.HttpHeadersInvalid;
            switch (line[0]) {
                ' ', '\t' => return error.HttpHeaderContinuationsUnsupported,
                else => {},
            }
            var line_it = mem.split(u8, line, ": ");
            const header_name = line_it.first();
            const header_value = line_it.rest();
            if (std.ascii.eqlIgnoreCase(header_name, "location")) {
                if (headers.location != null) return error.HttpHeadersInvalid;
                headers.location = header_value;
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-length")) {
                if (headers.content_length != null) return error.HttpHeadersInvalid;
                headers.content_length = try std.fmt.parseInt(u64, header_value, 10);
            } else if (std.ascii.eqlIgnoreCase(header_name, "transfer-encoding")) {
                // FIX:
                // if (headers.transfer_encoding != null or headers.transfer_compression != null) return error.HttpHeadersInvalid;

                // Transfer-Encoding: second, first
                // Transfer-Encoding: deflate, chunked
                var iter = std.mem.splitBackwards(u8, header_value, ",");

                if (iter.next()) |first| {
                    const trimmed = std.mem.trim(u8, first, " ");

                    if (std.meta.stringToEnum(http.TransferEncoding, trimmed)) |te| {
                        headers.transfer_encoding = te;
                    } else if (std.meta.stringToEnum(http.ContentEncoding, trimmed)) |ce| {
                        headers.transfer_compression = ce;
                    } else {
                        return error.HttpTransferEncodingUnsupported;
                    }
                }

                if (iter.next()) |second| {
                    // FIX:
                    // if (headers.transfer_compression != null) return error.HttpTransferEncodingUnsupported;

                    const trimmed = std.mem.trim(u8, second, " ");

                    if (std.meta.stringToEnum(http.ContentEncoding, trimmed)) |ce| {
                        headers.transfer_compression = ce;
                    } else {
                        return error.HttpTransferEncodingUnsupported;
                    }
                }

                if (iter.next()) |_| return error.HttpTransferEncodingUnsupported;
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-encoding")) {
                if (headers.transfer_compression != null) return error.HttpHeadersInvalid;

                const trimmed = std.mem.trim(u8, header_value, " ");

                if (std.meta.stringToEnum(http.ContentEncoding, trimmed)) |ce| {
                    headers.transfer_compression = ce;
                } else {
                    return error.HttpTransferEncodingUnsupported;
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "connection")) {
                if (std.ascii.eqlIgnoreCase(header_value, "keep-alive")) {
                    headers.connection = .keep_alive;
                } else if (std.ascii.eqlIgnoreCase(header_value, "close")) {
                    headers.connection = .close;
                } else {
                    return error.HttpConnectionHeaderUnsupported;
                }
            } else if (std.ascii.eqlIgnoreCase(header_name, "upgrade")) {
                headers.upgrade = header_value;
            }
        }

        return headers;
    }
};
