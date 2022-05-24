// Extend zig-libcurl functionality
// Add functions to read HTTP header
// Copy some private functions from zig-libcurl package

const std = @import("std");
// pub usingnamespace @import("curl");
const libcurl = @import("curl");
pub usingnamespace libcurl;

pub fn setHeaderWriteFn(self: *libcurl.Easy, write: libcurl.WriteFn) libcurl.Error!void {
    return tryCurl(libcurl.c.curl_easy_setopt(self, libcurl.c.CURLOPT_HEADERFUNCTION, write));
}

pub fn setHeaderWriteData(self: *libcurl.Easy, data: *anyopaque) libcurl.Error!void {
    return tryCurl(libcurl.c.curl_easy_setopt(self, libcurl.c.CURLOPT_HEADERDATA, data));
}

pub fn getContentType(self: *libcurl.Easy) libcurl.Error!?[*:0]u8 {
    var ct: ?[*:0]u8 = undefined;
    try tryCurl(libcurl.c.curl_easy_getinfo(self, libcurl.c.CURLINFO_CONTENT_TYPE, &ct));
    return ct;
}

pub fn getEffectiveUrl(self: *libcurl.Easy) libcurl.Error!?[*:0]u8 {
    var url: ?[*:0]u8 = null;
    try tryCurl(libcurl.c.curl_easy_getinfo(self, libcurl.c.CURLINFO_EFFECTIVE_URL, &url));
    return url;
}

// zig-curl package tryCurl fn is private
pub fn tryCurl(code: libcurl.c.CURLcode) libcurl.Error!void {
    if (code != libcurl.c.CURLE_OK)
        return errorFromCurl(code);
}

fn errorFromCurl(code: libcurl.c.CURLcode) libcurl.Error {
    return switch (code) {
        libcurl.c.CURLE_UNSUPPORTED_PROTOCOL => error.UnsupportedProtocol,
        libcurl.c.CURLE_FAILED_INIT => error.FailedInit,
        libcurl.c.CURLE_URL_MALFORMAT => error.UrlMalformat,
        libcurl.c.CURLE_NOT_BUILT_IN => error.NotBuiltIn,
        libcurl.c.CURLE_COULDNT_RESOLVE_PROXY => error.CouldntResolveProxy,
        libcurl.c.CURLE_COULDNT_RESOLVE_HOST => error.CouldntResolveHost,
        libcurl.c.CURLE_COULDNT_CONNECT => error.CounldntConnect,
        libcurl.c.CURLE_WEIRD_SERVER_REPLY => error.WeirdServerReply,
        libcurl.c.CURLE_REMOTE_ACCESS_DENIED => error.RemoteAccessDenied,
        libcurl.c.CURLE_FTP_ACCEPT_FAILED => error.FtpAcceptFailed,
        libcurl.c.CURLE_FTP_WEIRD_PASS_REPLY => error.FtpWeirdPassReply,
        libcurl.c.CURLE_FTP_ACCEPT_TIMEOUT => error.FtpAcceptTimeout,
        libcurl.c.CURLE_FTP_WEIRD_PASV_REPLY => error.FtpWeirdPasvReply,
        libcurl.c.CURLE_FTP_WEIRD_227_FORMAT => error.FtpWeird227Format,
        libcurl.c.CURLE_FTP_CANT_GET_HOST => error.FtpCantGetHost,
        libcurl.c.CURLE_HTTP2 => error.Http2,
        libcurl.c.CURLE_FTP_COULDNT_SET_TYPE => error.FtpCouldntSetType,
        libcurl.c.CURLE_PARTIAL_FILE => error.PartialFile,
        libcurl.c.CURLE_FTP_COULDNT_RETR_FILE => error.FtpCouldntRetrFile,
        libcurl.c.CURLE_OBSOLETE20 => error.Obsolete20,
        libcurl.c.CURLE_QUOTE_ERROR => error.QuoteError,
        libcurl.c.CURLE_HTTP_RETURNED_ERROR => error.HttpReturnedError,
        libcurl.c.CURLE_WRITE_ERROR => error.WriteError,
        libcurl.c.CURLE_OBSOLETE24 => error.Obsolete24,
        libcurl.c.CURLE_UPLOAD_FAILED => error.UploadFailed,
        libcurl.c.CURLE_READ_ERROR => error.ReadError,
        libcurl.c.CURLE_OUT_OF_MEMORY => error.OutOfMemory,
        libcurl.c.CURLE_OPERATION_TIMEDOUT => error.OperationTimeout,
        libcurl.c.CURLE_OBSOLETE29 => error.Obsolete29,
        libcurl.c.CURLE_FTP_PORT_FAILED => error.FtpPortFailed,
        libcurl.c.CURLE_FTP_COULDNT_USE_REST => error.FtpCouldntUseRest,
        libcurl.c.CURLE_OBSOLETE32 => error.Obsolete32,
        libcurl.c.CURLE_RANGE_ERROR => error.RangeError,
        libcurl.c.CURLE_HTTP_POST_ERROR => error.HttpPostError,
        libcurl.c.CURLE_SSL_CONNECT_ERROR => error.SslConnectError,
        libcurl.c.CURLE_BAD_DOWNLOAD_RESUME => error.BadDownloadResume,
        libcurl.c.CURLE_FILE_COULDNT_READ_FILE => error.FileCouldntReadFile,
        libcurl.c.CURLE_LDAP_CANNOT_BIND => error.LdapCannotBind,
        libcurl.c.CURLE_LDAP_SEARCH_FAILED => error.LdapSearchFailed,
        libcurl.c.CURLE_OBSOLETE40 => error.Obsolete40,
        libcurl.c.CURLE_FUNCTION_NOT_FOUND => error.FunctionNotFound,
        libcurl.c.CURLE_ABORTED_BY_CALLBACK => error.AbortByCallback,
        libcurl.c.CURLE_BAD_FUNCTION_ARGUMENT => error.BadFunctionArgument,
        libcurl.c.CURLE_OBSOLETE44 => error.Obsolete44,
        libcurl.c.CURLE_INTERFACE_FAILED => error.InterfaceFailed,
        libcurl.c.CURLE_OBSOLETE46 => error.Obsolete46,
        libcurl.c.CURLE_TOO_MANY_REDIRECTS => error.TooManyRedirects,
        libcurl.c.CURLE_UNKNOWN_OPTION => error.UnknownOption,
        libcurl.c.CURLE_SETOPT_OPTION_SYNTAX => error.SetoptOptionSyntax,
        libcurl.c.CURLE_OBSOLETE50 => error.Obsolete50,
        libcurl.c.CURLE_OBSOLETE51 => error.Obsolete51,
        libcurl.c.CURLE_GOT_NOTHING => error.GotNothing,
        libcurl.c.CURLE_SSL_ENGINE_NOTFOUND => error.SslEngineNotfound,
        libcurl.c.CURLE_SSL_ENGINE_SETFAILED => error.SslEngineSetfailed,
        libcurl.c.CURLE_SEND_ERROR => error.SendError,
        libcurl.c.CURLE_RECV_ERROR => error.RecvError,
        libcurl.c.CURLE_OBSOLETE57 => error.Obsolete57,
        libcurl.c.CURLE_SSL_CERTPROBLEM => error.SslCertproblem,
        libcurl.c.CURLE_SSL_CIPHER => error.SslCipher,
        libcurl.c.CURLE_PEER_FAILED_VERIFICATION => error.PeerFailedVerification,
        libcurl.c.CURLE_BAD_CONTENT_ENCODING => error.BadContentEncoding,
        libcurl.c.CURLE_LDAP_INVALID_URL => error.LdapInvalidUrl,
        libcurl.c.CURLE_FILESIZE_EXCEEDED => error.FilesizeExceeded,
        libcurl.c.CURLE_USE_SSL_FAILED => error.UseSslFailed,
        libcurl.c.CURLE_SEND_FAIL_REWIND => error.SendFailRewind,
        libcurl.c.CURLE_SSL_ENGINE_INITFAILED => error.SslEngineInitfailed,
        libcurl.c.CURLE_LOGIN_DENIED => error.LoginDenied,
        libcurl.c.CURLE_TFTP_NOTFOUND => error.TftpNotfound,
        libcurl.c.CURLE_TFTP_PERM => error.TftpPerm,
        libcurl.c.CURLE_REMOTE_DISK_FULL => error.RemoteDiskFull,
        libcurl.c.CURLE_TFTP_ILLEGAL => error.TftpIllegal,
        libcurl.c.CURLE_TFTP_UNKNOWNID => error.Tftp_Unknownid,
        libcurl.c.CURLE_REMOTE_FILE_EXISTS => error.RemoteFileExists,
        libcurl.c.CURLE_TFTP_NOSUCHUSER => error.TftpNosuchuser,
        libcurl.c.CURLE_CONV_FAILED => error.ConvFailed,
        libcurl.c.CURLE_CONV_REQD => error.ConvReqd,
        libcurl.c.CURLE_SSL_CACERT_BADFILE => error.SslCacertBadfile,
        libcurl.c.CURLE_REMOTE_FILE_NOT_FOUND => error.RemoteFileNotFound,
        libcurl.c.CURLE_SSH => error.Ssh,
        libcurl.c.CURLE_SSL_SHUTDOWN_FAILED => error.SslShutdownFailed,
        libcurl.c.CURLE_AGAIN => error.Again,
        libcurl.c.CURLE_SSL_CRL_BADFILE => error.SslCrlBadfile,
        libcurl.c.CURLE_SSL_ISSUER_ERROR => error.SslIssuerError,
        libcurl.c.CURLE_FTP_PRET_FAILED => error.FtpPretFailed,
        libcurl.c.CURLE_RTSP_CSEQ_ERROR => error.RtspCseqError,
        libcurl.c.CURLE_RTSP_SESSION_ERROR => error.RtspSessionError,
        libcurl.c.CURLE_FTP_BAD_FILE_LIST => error.FtpBadFileList,
        libcurl.c.CURLE_CHUNK_FAILED => error.ChunkFailed,
        libcurl.c.CURLE_NO_CONNECTION_AVAILABLE => error.NoConnectionAvailable,
        libcurl.c.CURLE_SSL_PINNEDPUBKEYNOTMATCH => error.SslPinnedpubkeynotmatch,
        libcurl.c.CURLE_SSL_INVALIDCERTSTATUS => error.SslInvalidcertstatus,
        libcurl.c.CURLE_HTTP2_STREAM => error.Http2Stream,
        libcurl.c.CURLE_RECURSIVE_API_CALL => error.RecursiveApiCall,
        libcurl.c.CURLE_AUTH_ERROR => error.AuthError,
        libcurl.c.CURLE_HTTP3 => error.Http3,
        libcurl.c.CURLE_QUIC_CONNECT_ERROR => error.QuicConnectError,
        libcurl.c.CURLE_PROXY => error.Proxy,
        libcurl.c.CURLE_SSL_CLIENTCERT => error.SslClientCert,

        else => blk: {
            std.debug.assert(false);
            break :blk error.UnknownErrorCode;
        },
    };
}

pub fn getLastHeader(headers_str: []const u8) []const u8 {
    const sep = "\r\n\r\n";
    const header_start = std.mem.lastIndexOfLinear(u8, headers_str[0 .. headers_str.len - sep.len], sep) orelse 0;
    // If there is only one header (no redirects) 4 characters from start of the status line
    // will be remove. Don't care about it
    return headers_str[header_start + sep.len ..];
}

pub fn getHeaderValue(header: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.split(u8, header, "\r\n");
    while (iter.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, key)) {
            const value = line[key.len + 1 ..];
            const last_index = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
            return std.mem.trim(u8, value[0..last_index], "\r\n ");
        }
    }
    return null;
}
