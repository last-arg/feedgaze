// Code taken from Zig std.http.Client.

//! TODO: send connection: keep-alive and LRU cache a configurable number of
//! open connections to skip DNS and TLS handshake for subsequent requests.
//!
//! This API is *not* thread safe.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const http = std.http;
const net = std.net;
const Client = @This();
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const print = std.debug.print;
const log = std.log;
const feed_types = @import("./feed_types.zig");
const ContentType = feed_types.ContentType;

/// Used for tcpConnectToHost and storing HTTP headers when an externally
/// managed buffer is not provided.
allocator: Allocator,
ca_bundle: std.crypto.Certificate.Bundle = .{},
/// When this is `true`, the next time this client performs an HTTPS request,
/// it will first rescan the system for root certificates.
next_https_rescan_certs: bool = true,

pub const Connection = struct {
    stream: net.Stream,
    /// undefined unless protocol is tls.
    tls_client: std.crypto.tls.Client,
    protocol: Protocol,

    pub const Protocol = enum { plain, tls };

    pub fn read(conn: *Connection, buffer: []u8) !usize {
        switch (conn.protocol) {
            .plain => return conn.stream.read(buffer),
            .tls => return conn.tls_client.read(conn.stream, buffer),
        }
    }

    pub fn readAtLeast(conn: *Connection, buffer: []u8, len: usize) !usize {
        switch (conn.protocol) {
            .plain => return conn.stream.readAtLeast(buffer, len),
            .tls => return conn.tls_client.readAtLeast(conn.stream, buffer, len),
        }
    }

    pub fn writeAll(conn: *Connection, buffer: []const u8) !void {
        switch (conn.protocol) {
            .plain => return conn.stream.writeAll(buffer),
            .tls => return conn.tls_client.writeAll(conn.stream, buffer),
        }
    }

    pub fn write(conn: *Connection, buffer: []const u8) !usize {
        switch (conn.protocol) {
            .plain => return conn.stream.write(buffer),
            .tls => return conn.tls_client.write(conn.stream, buffer),
        }
    }
};

/// TODO: emit error.UnexpectedEndOfStream or something like that when the read
/// data does not match the content length. This is necessary since HTTPS disables
/// close_notify protection on underlying TLS streams.
pub const Request = struct {
    client: *Client,
    connection: Connection,
    redirects_left: u32,
    response: Response,
    /// These are stored in Request so that they are available when following
    /// redirects.
    headers: Headers,

    pub const Response = struct {
        headers: Response.Headers,
        state: State,
        header_bytes_owned: bool,
        /// This could either be a fixed buffer provided by the API user or it
        /// could be our own array list.
        header_bytes: std.ArrayListUnmanaged(u8),
        max_header_bytes: usize,
        next_chunk_length: u64,

        pub const Headers = struct {
            status: http.Status,
            version: http.Version,
            location: ?[]const u8 = null,
            content_length: ?u64 = null,
            transfer_encoding: ?http.TransferEncoding = null,

            pub fn parse(bytes: []const u8) !Response.Headers {
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

                var headers: Response.Headers = .{
                    .version = version,
                    .status = status,
                };

                while (it.next()) |line| {
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
                        if (headers.transfer_encoding != null) return error.HttpHeadersInvalid;
                        headers.transfer_encoding = std.meta.stringToEnum(http.TransferEncoding, header_value) orelse
                            return error.HttpTransferEncodingUnsupported;
                    }
                }

                return headers;
            }
        };

        pub const State = enum {
            /// Begin header parsing states.
            invalid,
            start,
            seen_r,
            seen_rn,
            seen_rnr,
            finished,
            /// Begin transfer-encoding: chunked parsing states.
            chunk_size_prefix_r,
            chunk_size_prefix_n,
            chunk_size,
            chunk_r,
            chunk_data,

            pub fn zeroMeansEnd(state: State) bool {
                return switch (state) {
                    .finished, .chunk_data => true,
                    else => false,
                };
            }
        };

        pub fn initDynamic(max: usize) Response {
            return .{
                .state = .start,
                .headers = undefined,
                .header_bytes = .{},
                .max_header_bytes = max,
                .header_bytes_owned = true,
                .next_chunk_length = undefined,
            };
        }

        pub fn initStatic(buf: []u8) Response {
            return .{
                .state = .start,
                .headers = undefined,
                .header_bytes = .{ .items = buf[0..0], .capacity = buf.len },
                .max_header_bytes = buf.len,
                .header_bytes_owned = false,
                .next_chunk_length = undefined,
            };
        }

        /// Returns how many bytes are part of HTTP headers. Always less than or
        /// equal to bytes.len. If the amount returned is less than bytes.len, it
        /// means the headers ended and the first byte after the double \r\n\r\n is
        /// located at `bytes[result]`.
        pub fn findHeadersEnd(r: *Response, bytes: []const u8) usize {
            var index: usize = 0;

            // TODO: https://github.com/ziglang/zig/issues/8220
            state: while (true) {
                switch (r.state) {
                    .invalid => unreachable,
                    .finished => unreachable,
                    .start => while (true) {
                        switch (bytes.len - index) {
                            0 => return index,
                            1 => {
                                if (bytes[index] == '\r')
                                    r.state = .seen_r;
                                return index + 1;
                            },
                            2 => {
                                if (int16(bytes[index..][0..2]) == int16("\r\n")) {
                                    r.state = .seen_rn;
                                } else if (bytes[index + 1] == '\r') {
                                    r.state = .seen_r;
                                }
                                return index + 2;
                            },
                            3 => {
                                if (int16(bytes[index..][0..2]) == int16("\r\n") and
                                    bytes[index + 2] == '\r')
                                {
                                    r.state = .seen_rnr;
                                } else if (int16(bytes[index + 1 ..][0..2]) == int16("\r\n")) {
                                    r.state = .seen_rn;
                                } else if (bytes[index + 2] == '\r') {
                                    r.state = .seen_r;
                                }
                                return index + 3;
                            },
                            4...15 => {
                                if (int32(bytes[index..][0..4]) == int32("\r\n\r\n")) {
                                    r.state = .finished;
                                    return index + 4;
                                } else if (int16(bytes[index + 1 ..][0..2]) == int16("\r\n") and
                                    bytes[index + 3] == '\r')
                                {
                                    r.state = .seen_rnr;
                                    index += 4;
                                    continue :state;
                                } else if (int16(bytes[index + 2 ..][0..2]) == int16("\r\n")) {
                                    r.state = .seen_rn;
                                    index += 4;
                                    continue :state;
                                } else if (bytes[index + 3] == '\r') {
                                    r.state = .seen_r;
                                    index += 4;
                                    continue :state;
                                }
                                index += 4;
                                continue;
                            },
                            else => {
                                const chunk = bytes[index..][0..16];
                                const v: @Vector(16, u8) = chunk.*;
                                const matches_r = v == @splat(16, @as(u8, '\r'));
                                const iota = std.simd.iota(u8, 16);
                                const default = @splat(16, @as(u8, 16));
                                const sub_index = @reduce(.Min, @select(u8, matches_r, iota, default));
                                switch (sub_index) {
                                    0...12 => {
                                        index += sub_index + 4;
                                        if (int32(chunk[sub_index..][0..4]) == int32("\r\n\r\n")) {
                                            r.state = .finished;
                                            return index;
                                        }
                                        continue;
                                    },
                                    13 => {
                                        index += 16;
                                        if (int16(chunk[14..][0..2]) == int16("\n\r")) {
                                            r.state = .seen_rnr;
                                            continue :state;
                                        }
                                        continue;
                                    },
                                    14 => {
                                        index += 16;
                                        if (chunk[15] == '\n') {
                                            r.state = .seen_rn;
                                            continue :state;
                                        }
                                        continue;
                                    },
                                    15 => {
                                        r.state = .seen_r;
                                        index += 16;
                                        continue :state;
                                    },
                                    16 => {
                                        index += 16;
                                        continue;
                                    },
                                    else => unreachable,
                                }
                            },
                        }
                    },

                    .seen_r => switch (bytes.len - index) {
                        0 => return index,
                        1 => {
                            switch (bytes[index]) {
                                '\n' => r.state = .seen_rn,
                                '\r' => r.state = .seen_r,
                                else => r.state = .start,
                            }
                            return index + 1;
                        },
                        2 => {
                            if (int16(bytes[index..][0..2]) == int16("\n\r")) {
                                r.state = .seen_rnr;
                                return index + 2;
                            }
                            r.state = .start;
                            return index + 2;
                        },
                        else => {
                            if (int16(bytes[index..][0..2]) == int16("\n\r") and
                                bytes[index + 2] == '\n')
                            {
                                r.state = .finished;
                                return index + 3;
                            }
                            index += 3;
                            r.state = .start;
                            continue :state;
                        },
                    },
                    .seen_rn => switch (bytes.len - index) {
                        0 => return index,
                        1 => {
                            switch (bytes[index]) {
                                '\r' => r.state = .seen_rnr,
                                else => r.state = .start,
                            }
                            return index + 1;
                        },
                        else => {
                            if (int16(bytes[index..][0..2]) == int16("\r\n")) {
                                r.state = .finished;
                                return index + 2;
                            }
                            index += 2;
                            r.state = .start;
                            continue :state;
                        },
                    },
                    .seen_rnr => switch (bytes.len - index) {
                        0 => return index,
                        else => {
                            if (bytes[index] == '\n') {
                                r.state = .finished;
                                return index + 1;
                            }
                            index += 1;
                            r.state = .start;
                            continue :state;
                        },
                    },
                    .chunk_size_prefix_r => unreachable,
                    .chunk_size_prefix_n => unreachable,
                    .chunk_size => unreachable,
                    .chunk_r => unreachable,
                    .chunk_data => unreachable,
                }

                return index;
            }
        }

        pub fn findChunkedLen(r: *Response, bytes: []const u8) usize {
            var i: usize = 0;
            if (r.state == .chunk_size) {
                while (i < bytes.len) : (i += 1) {
                    const digit = switch (bytes[i]) {
                        '0'...'9' => |b| b - '0',
                        'A'...'Z' => |b| b - 'A' + 10,
                        'a'...'z' => |b| b - 'a' + 10,
                        '\r' => {
                            r.state = .chunk_r;
                            i += 1;
                            break;
                        },
                        else => {
                            r.state = .invalid;
                            return i;
                        },
                    };
                    const mul = @mulWithOverflow(r.next_chunk_length, 16);
                    if (mul[1] != 0) {
                        r.state = .invalid;
                        return i;
                    }
                    const add = @addWithOverflow(mul[0], digit);
                    if (add[1] != 0) {
                        r.state = .invalid;
                        return i;
                    }
                    r.next_chunk_length = add[0];
                } else {
                    return i;
                }
            }
            assert(r.state == .chunk_r);
            if (i == bytes.len) return i;

            if (bytes[i] == '\n') {
                r.state = .chunk_data;
                return i + 1;
            } else {
                r.state = .invalid;
                return i;
            }
        }

        fn parseInt3(nnn: @Vector(3, u8)) u10 {
            const zero: @Vector(3, u8) = .{ '0', '0', '0' };
            const mmm: @Vector(3, u10) = .{ 100, 10, 1 };
            return @reduce(.Add, @as(@Vector(3, u10), nnn -% zero) *% mmm);
        }
    };

    pub const Headers = struct {
        version: http.Version = .@"HTTP/1.1",
        method: http.Method = .GET,
    };

    pub const Options = struct {
        max_redirects: u32 = 3,
        header_strategy: HeaderStrategy = .{ .dynamic = 16 * 1024 },

        pub const HeaderStrategy = union(enum) {
            /// In this case, the client's Allocator will be used to store the
            /// entire HTTP header. This value is the maximum total size of
            /// HTTP headers allowed, otherwise
            /// error.HttpHeadersExceededSizeLimit is returned from read().
            dynamic: usize,
            /// This is used to store the entire HTTP header. If the HTTP
            /// header is too big to fit, `error.HttpHeadersExceededSizeLimit`
            /// is returned from read(). When this is used, `error.OutOfMemory`
            /// cannot be returned from `read()`.
            static: []u8,
        };
    };

    /// May be skipped if header strategy is buffer.
    pub fn deinit(req: *Request) void {
        if (req.response.header_bytes_owned) {
            req.response.header_bytes.deinit(req.client.allocator);
        }
        req.* = undefined;
    }

    pub const Reader = std.io.Reader(*Request, ReadError, read);

    pub fn reader(req: *Request) Reader {
        return .{ .context = req };
    }

    pub fn readAll(req: *Request, buffer: []u8) !usize {
        return readAtLeast(req, buffer, buffer.len);
    }

    pub const ReadError = net.Stream.ReadError || error{
        // From HTTP protocol
        HttpHeadersInvalid,
        HttpHeadersExceededSizeLimit,
        HttpRedirectMissingLocation,
        HttpTransferEncodingUnsupported,
        HttpContentLengthUnknown,
        TooManyHttpRedirects,
        ShortHttpStatusLine,
        BadHttpVersion,
        HttpHeaderContinuationsUnsupported,
        UnsupportedUrlScheme,
        UriMissingHost,
        UnknownHostName,

        // Network problems
        NetworkUnreachable,
        HostLacksNetworkAddresses,
        TemporaryNameServerFailure,
        NameServerFailure,
        ProtocolFamilyNotAvailable,
        ProtocolNotSupported,

        // System resource problems
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        OutOfMemory,

        // TLS problems
        InsufficientEntropy,
        TlsConnectionTruncated,
        TlsRecordOverflow,
        TlsDecodeError,
        TlsAlert,
        TlsBadRecordMac,
        TlsBadLength,
        TlsIllegalParameter,
        TlsUnexpectedMessage,
        TlsDecryptFailure,
        CertificateFieldHasInvalidLength,
        CertificateHostMismatch,
        CertificatePublicKeyInvalid,
        CertificateExpired,
        CertificateFieldHasWrongDataType,
        CertificateIssuerMismatch,
        CertificateNotYetValid,
        CertificateSignatureAlgorithmMismatch,
        CertificateSignatureAlgorithmUnsupported,
        CertificateSignatureInvalid,
        CertificateSignatureInvalidLength,
        CertificateSignatureNamedCurveUnsupported,
        CertificateSignatureUnsupportedBitCount,
        TlsCertificateNotVerified,
        TlsBadSignatureScheme,
        TlsBadRsaSignatureBitCount,
        TlsDecryptError,
        UnsupportedCertificateVersion,
        CertificateTimeInvalid,
        CertificateHasUnrecognizedObjectId,
        CertificateHasInvalidBitString,
        CertificateAuthorityBundleTooBig,

        // TODO: convert to higher level errors
        InvalidFormat,
        InvalidPort,
        UnexpectedCharacter,
        Overflow,
        InvalidCharacter,
        AddressFamilyNotSupported,
        AddressInUse,
        AddressNotAvailable,
        ConnectionPending,
        ConnectionRefused,
        FileNotFound,
        PermissionDenied,
        ServiceUnavailable,
        SocketTypeNotSupported,
        FileTooBig,
        LockViolation,
        NoSpaceLeft,
        NotOpenForWriting,
        InvalidEncoding,
        IdentityElement,
        NonCanonical,
        SignatureVerificationFailed,
        MessageTooLong,
        NegativeIntoUnsigned,
        TargetTooSmall,
        BufferTooSmall,
        InvalidSignature,
        NotSquare,
        DiskQuota,
        InvalidEnd,
        Incomplete,
        InvalidIpv4Mapping,
        InvalidIPAddressFormat,
        BadPathName,
        DeviceBusy,
        FileBusy,
        FileLocksNotSupported,
        InvalidHandle,
        InvalidUtf8,
        NameTooLong,
        NoDevice,
        PathAlreadyExists,
        PipeBusy,
        SharingViolation,
        SymLinkLoop,
        FileSystem,
        InterfaceNotFound,
        AlreadyBound,
        FileDescriptorNotASocket,
        NetworkSubsystemFailed,
        NotDir,
        ReadOnlyFileSystem,
        Unseekable,
        MissingEndCertificateMarker,
        InvalidPadding,
        EndOfStream,
    };

    pub fn read(req: *Request, buffer: []u8) ReadError!usize {
        return readAtLeast(req, buffer, 1);
    }

    pub fn readAtLeast(req: *Request, buffer: []u8, len: usize) !usize {
        assert(len <= buffer.len);
        var index: usize = 0;
        while (index < len) {
            const zero_means_end = req.response.state.zeroMeansEnd();
            const amt = try readAdvanced(req, buffer[index..]);
            if (amt == 0 and zero_means_end) break;
            index += amt;
        }
        return index;
    }

    /// This one can return 0 without meaning EOF.
    /// TODO change to readvAdvanced
    pub fn readAdvanced(req: *Request, buffer: []u8) !usize {
        var in = buffer[0..try req.connection.read(buffer)];
        var out_index: usize = 0;
        while (true) {
            switch (req.response.state) {
                .invalid => unreachable,
                .start, .seen_r, .seen_rn, .seen_rnr => {
                    const i = req.response.findHeadersEnd(in);
                    if (req.response.state == .invalid) return error.HttpHeadersInvalid;

                    const headers_data = in[0..i];
                    if (req.response.header_bytes.items.len + headers_data.len > req.response.max_header_bytes) {
                        return error.HttpHeadersExceededSizeLimit;
                    }
                    try req.response.header_bytes.appendSlice(req.client.allocator, headers_data);

                    if (req.response.state == .finished) {
                        req.response.headers = try Response.Headers.parse(req.response.header_bytes.items);

                        if (req.response.headers.status.class() == .redirect) {
                            if (req.redirects_left == 0) return error.TooManyHttpRedirects;
                            const location = req.response.headers.location orelse
                                return error.HttpRedirectMissingLocation;
                            const new_url = try std.Uri.parse(location);
                            const new_req = try req.client.request(new_url, req.headers, .{
                                .max_redirects = req.redirects_left - 1,
                                .header_strategy = if (req.response.header_bytes_owned) .{
                                    .dynamic = req.response.max_header_bytes,
                                } else .{
                                    .static = req.response.header_bytes.unusedCapacitySlice(),
                                },
                            });
                            req.deinit();
                            req.* = new_req;
                            assert(out_index == 0);
                            in = buffer[0..try req.connection.read(buffer)];
                            continue;
                        }

                        if (req.response.headers.transfer_encoding) |transfer_encoding| {
                            switch (transfer_encoding) {
                                .chunked => {
                                    req.response.next_chunk_length = 0;
                                    req.response.state = .chunk_size;
                                },
                                .compress => return error.HttpTransferEncodingUnsupported,
                                .deflate => return error.HttpTransferEncodingUnsupported,
                                .gzip => return error.HttpTransferEncodingUnsupported,
                            }
                        } else if (req.response.headers.content_length) |content_length| {
                            req.response.next_chunk_length = content_length;
                        } else {
                            return error.HttpContentLengthUnknown;
                        }

                        in = in[i..];
                        continue;
                    }

                    assert(out_index == 0);
                    return 0;
                },
                .finished => {
                    if (in.ptr == buffer.ptr) {
                        return in.len;
                    } else {
                        mem.copy(u8, buffer[out_index..], in);
                        return out_index + in.len;
                    }
                },
                .chunk_size_prefix_r => switch (in.len) {
                    0 => return out_index,
                    1 => switch (in[0]) {
                        '\r' => {
                            req.response.state = .chunk_size_prefix_n;
                            return out_index;
                        },
                        else => {
                            req.response.state = .invalid;
                            return error.HttpHeadersInvalid;
                        },
                    },
                    else => switch (int16(in[0..2])) {
                        int16("\r\n") => {
                            in = in[2..];
                            req.response.state = .chunk_size;
                            continue;
                        },
                        else => {
                            req.response.state = .invalid;
                            return error.HttpHeadersInvalid;
                        },
                    },
                },
                .chunk_size_prefix_n => switch (in.len) {
                    0 => return out_index,
                    else => switch (in[0]) {
                        '\n' => {
                            in = in[1..];
                            req.response.state = .chunk_size;
                            continue;
                        },
                        else => {
                            req.response.state = .invalid;
                            return error.HttpHeadersInvalid;
                        },
                    },
                },
                .chunk_size, .chunk_r => {
                    const i = req.response.findChunkedLen(in);
                    switch (req.response.state) {
                        .invalid => return error.HttpHeadersInvalid,
                        .chunk_data => {
                            if (req.response.next_chunk_length == 0) {
                                req.response.state = .start;
                                return out_index;
                            }
                            in = in[i..];
                            continue;
                        },
                        .chunk_size => return out_index,
                        else => unreachable,
                    }
                },
                .chunk_data => {
                    // TODO https://github.com/ziglang/zig/issues/14039
                    const sub_amt = @intCast(usize, @min(req.response.next_chunk_length, in.len));
                    req.response.next_chunk_length -= sub_amt;
                    if (req.response.next_chunk_length > 0) {
                        if (in.ptr == buffer.ptr) {
                            return sub_amt;
                        } else {
                            mem.copy(u8, buffer[out_index..], in[0..sub_amt]);
                            out_index += sub_amt;
                            return out_index;
                        }
                    }
                    mem.copy(u8, buffer[out_index..], in[0..sub_amt]);
                    out_index += sub_amt;
                    req.response.state = .chunk_size_prefix_r;
                    in = in[sub_amt..];
                    continue;
                },
            }
        }
    }

    inline fn int16(array: *const [2]u8) u16 {
        return @bitCast(u16, array.*);
    }

    inline fn int32(array: *const [4]u8) u32 {
        return @bitCast(u32, array.*);
    }

    inline fn int64(array: *const [8]u8) u64 {
        return @bitCast(u64, array.*);
    }
};

/// TODO: emit error.UnexpectedEndOfStream or something like that when the read
/// data does not match the content length. This is necessary since HTTPS disables
/// close_notify protection on underlying TLS streams.
pub fn deinit(client: *Client) void {
    client.ca_bundle.deinit(client.allocator);
    client.* = undefined;
}

pub fn connect(client: *Client, host: []const u8, port: u16, protocol: Connection.Protocol) !Connection {
    var conn: Connection = .{
        .stream = try net.tcpConnectToHost(client.allocator, host, port),
        .tls_client = undefined,
        .protocol = protocol,
    };

    switch (protocol) {
        .plain => {},
        .tls => {
            conn.tls_client = try std.crypto.tls.Client.init(conn.stream, client.ca_bundle, host);
            // This is appropriate for HTTPS because the HTTP headers contain
            // the content length which is used to detect truncation attacks.
            conn.tls_client.allow_truncation_attacks = true;
        },
    }

    return conn;
}

pub fn request(client: *Client, uri: Uri, headers: Request.Headers, options: Request.Options) !Request {
    const protocol: Connection.Protocol = if (mem.eql(u8, uri.scheme, "http"))
        .plain
    else if (mem.eql(u8, uri.scheme, "https"))
        .tls
    else
        return error.UnsupportedUrlScheme;

    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };

    const host = uri.host orelse return error.UriMissingHost;

    if (client.next_https_rescan_certs and protocol == .tls) {
        try client.ca_bundle.rescan(client.allocator);
        client.next_https_rescan_certs = false;
    }

    var req: Request = .{
        .client = client,
        .headers = headers,
        .connection = try client.connect(host, port, protocol),
        .redirects_left = options.max_redirects,
        .response = switch (options.header_strategy) {
            .dynamic => |max| Request.Response.initDynamic(max),
            .static => |buf| Request.Response.initStatic(buf),
        },
    };

    {
        var h = try std.BoundedArray(u8, 1024).init(0);
        // Header status line
        try h.appendSlice(@tagName(headers.method));
        try h.appendSlice(" ");
        try h.appendSlice(uri.path);
        try h.appendSlice(" ");
        try h.appendSlice(@tagName(headers.version));
        // Header 'key: value'
        try h.appendSlice("\r\nHost: ");
        try h.appendSlice(host);
        try h.appendSlice("\r\nAccept: application/atom+xml, application/rss+xml, text/xml, application/xml");
        try h.appendSlice("\r\nConnection: close\r\n\r\n");

        const header_bytes = h.slice();
        try req.connection.writeAll(header_bytes);
    }

    return req;
}

// Last-Modified (If-Modified-Since)
// length 29
//
// ETag (If-Match)
// Has no set length. Set it to 128?
const HeaderValues = struct {
    content_type: ?ContentType = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    status: http.Status,
    max_age: ?u64 = null,

    pub fn fromResponse(resp: Request.Response) HeaderValues {
        const etag_key = "etag:";
        const content_type_key = "content-type:";
        const last_modified_key = "last-modified:";
        const cache_control_key = "cache-control:";

        var result: HeaderValues = .{
            .status = resp.headers.status,
        };
        var iter = std.mem.split(u8, resp.header_bytes.items, "\r\n");
        _ = iter.first();
        while (iter.next()) |line| {
            std.debug.print("|{s}|\n", .{line});
            if (std.ascii.startsWithIgnoreCase(line, etag_key)) {
                result.etag = std.mem.trim(u8, line[etag_key.len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, content_type_key)) {
                result.content_type = ContentType.fromString(std.mem.trim(u8, line[content_type_key.len..], " "));
            } else if (std.ascii.startsWithIgnoreCase(line, last_modified_key)) {
                result.last_modified = std.mem.trim(u8, line[last_modified_key.len..], " ");
            } else if (std.ascii.startsWithIgnoreCase(line, cache_control_key)) {
                var key_value_iter = std.mem.split(u8, line[cache_control_key.len..], ",");
                while (key_value_iter.next()) |key_value| {
                    var pair_iter = mem.split(u8, key_value, "=");
                    const key = pair_iter.next() orelse continue;
                    const value = pair_iter.next() orelse continue;
                    if (mem.eql(u8, "max-age", key)) {
                        result.max_age = std.fmt.parseUnsigned(u64, value, 10) catch continue;
                        break;
                    } else if (mem.eql(u8, "s-maxage", value)) {
                        result.max_age = std.fmt.parseUnsigned(u64, value, 10) catch continue;
                    }
                }
            }
        }
        return result;
    }
};

// Resources:
// https://jackevansevo.github.io/the-struggles-of-building-a-feed-reader.html
// https://kevincox.ca/2022/05/06/rss-feed-best-practices/

// Can start with:
// '<a '
// '<link '
// Example: '<link rel="alternate" type="application/rss+xml" title="Example" href="/rss.xml">'

// Possible file ends:
// '.rss'
// '.atom'
// '.xml'

// Common feed link patterns
// '/rss.xml'
// '/index.xml'
// '/atom.xml'
// '/feed.xml'
// '/feed'
// '/rss'
fn parseHtmlForFeedLinks(input: []const u8, feed_arr: *FeedLinkArray) !void {
    // print("|{s}|\n", .{input});
    var content = input;
    while (std.mem.indexOfScalar(u8, content, '<')) |start_index| {
        content = content[start_index + 1 ..];
        const is_a = std.ascii.startsWithIgnoreCase(content, "a ");
        const is_link = std.ascii.startsWithIgnoreCase(content, "link ");
        if (!is_a and !is_link) {
            if (std.mem.startsWith(u8, content, "!--")) {
                // Is a comment. Skip comment.
                content = content[4..];
                if (std.mem.indexOf(u8, content, "-->")) |end| {
                    print("comment\n", .{});
                    content = content[end + 1 ..];
                }
            }
            continue;
        }
        var end_index = std.mem.indexOfScalar(u8, content, '>') orelse return;
        if (is_link and content[end_index - 1] == '/') {
            end_index -= 1;
        }
        const new_start: usize = if (is_a) 2 else 5;
        var attrs_raw = content[new_start..end_index];
        content = content[end_index..];

        var rel: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var link: ?[]const u8 = null;
        var link_type: ?[]const u8 = null;

        while (mem.indexOfScalar(u8, attrs_raw, '=')) |eql_index| {
            const name = std.mem.trimLeft(u8, attrs_raw[0..eql_index], " ");
            attrs_raw = attrs_raw[eql_index + 1 ..];
            var sep: u8 = ' ';
            const first = attrs_raw[0];
            if (first == '\'' or first == '"') {
                sep = first;
                attrs_raw = attrs_raw[1..];
            }
            const attr_end = mem.indexOfScalar(u8, attrs_raw, sep) orelse attrs_raw.len;
            const value = attrs_raw[0..attr_end];
            if (attr_end != attrs_raw.len) {
                attrs_raw = attrs_raw[attr_end + 1 ..];
            }

            if (std.ascii.eqlIgnoreCase(name, "type")) {
                link_type = value;
            } else if (std.ascii.eqlIgnoreCase(name, "rel")) {
                rel = value;
            } else if (std.ascii.eqlIgnoreCase(name, "href")) {
                link = value;
            } else if (std.ascii.eqlIgnoreCase(name, "title")) {
                title = value;
            }
        }

        if (rel != null and link != null and link_type != null and
            std.ascii.eqlIgnoreCase(rel.?, "alternate"))
        {
            if (FeedLink.Type.fromString(link_type.?)) |valid_type| {
                const allocator = feed_arr.allocator;
                try feed_arr.append(.{
                    .title = if (title) |t| try allocator.dupe(u8, t) else null,
                    .link = try allocator.dupe(u8, link.?),
                    .type = valid_type,
                });
            }
        }
    }
}

const FeedLink = struct {
    link: []const u8,
    type: ContentType,
    title: ?[]const u8 = null,
};

const FeedLinkArray = std.ArrayList(FeedLink);

const FeedRequest = struct {
    client: Client,
    allocator: Allocator,
    request: ?*Request = null,

    const Response = struct {
        content: []const u8,
        headers: HeaderValues,
    };

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        var client: Client = .{ .allocator = allocator };
        errdefer client.deinit();
        try client.ca_bundle.rescan(allocator);
        return .{
            .client = client,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.request) |req| {
            req.deinit();
        }
        self.client.deinit();
    }

    pub fn fetch(self: *Self, url: Uri) !Self.Response {
        var req = try self.client.request(url, .{}, .{});
        self.request = &req;
        errdefer req.deinit();

        const buf_len = 8 * 1024;
        var buf: [buf_len]u8 = undefined;
        var amt = try req.readAll(&buf);

        const header_value = HeaderValues.fromResponse(req.response);
        const capacity = req.response.headers.content_length orelse buf_len;
        var content = try std.ArrayList(u8).initCapacity(self.allocator, capacity);
        defer content.deinit();
        content.appendSliceAssumeCapacity(buf[0..amt]);

        while (true) {
            amt = try req.readAll(buf[0..]);
            if (amt == 0) break;
            try content.appendSlice(buf[0..amt]);
        }

        return .{
            .content = try content.toOwnedSlice(),
            .headers = header_value,
        };
    }
};

test "http" {
    std.testing.log_level = .debug;
    print("=> Start http client test\n", .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fr = try FeedRequest.init(arena.allocator());
    defer fr.deinit();
    const input = "http://localhost:8282/rss2.xml";
    const url = try std.Uri.parse(input);
    const resp = try fr.fetch(url);
    // print("{}\n", .{fr.content});
    print("{?}\n", .{resp.headers});
    print("=> End http client test\n", .{});
}
