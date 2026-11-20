const util = @import("../util.zig");
const builtin = @import("builtin");
const feed_types = @import("../feed_types.zig");
const Server = @import("../server.zig");
const IconManage = Server.IconManage;
const Storage = @import("../storage.zig").Storage;
const UrlQueryError = Server.UrlQueryError;
const TagResult = Storage.TagResult;

fn hash_static_file(comptime path: []const u8) u64 {
    @setEvalBranchQuota(60000);
    const c = @embedFile(path);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(c);
    return hasher.final();
}

pub fn file_type(filename: []const u8) enum { js, css } {
    const last_dot_index = std.mem.lastIndexOfScalar(u8, filename, '.') orelse
        @compileError("'filename is missing file extension. Valid file extensions: js, css'");

    const filetype = filename[last_dot_index + 1 ..];
    if (std.mem.eql(u8, filetype, "css")) {
        return .css;
    } else if (std.mem.eql(u8, filetype, "js")) {
        return .js;
    }

    @compileError("File has to have .js or .css extension");
}

const path_server = if (builtin.mode == .debug) "../server/" else "../server/dist/";
pub const static_files_map = .{
    .{ .filename = "main.css", .hash = hash_static_file(path_server ++ "main.css") },
    .{ .filename = "main.js", .hash = hash_static_file(path_server ++ "main.js") },
    .{ .filename = "relative-time.js", .hash = hash_static_file(path_server ++ "relative-time.js") },
};

pub fn get_static_path(comptime filename: []const u8) []const u8 {
    const hash = comptime blk: {
        for (static_files_map) |file| {
            if (std.mem.eql(u8, file.filename, filename)) {
                break :blk file.hash;
            }
        }
        @compileError("Invalid static file input: " ++ filename);
    };

    return std.fmt.comptimePrint("/public/{x}-{s}", .{ hash, filename });
}

const reload_js = @embedFile("../server/reload.js");

const menu_items = [_]struct { path: []const u8, name: []const u8 }{
    .{ .path = "/feeds", .name = "Feeds" },
    .{ .path = "/tags", .name = "Tags" },
    .{ .path = "/feed/add", .name = "Add feed" },
    .{ .path = "/failed-requests", .name = "Failed feed requests" },
};

pub const Navigation = struct {
    current_path: []const u8 = "/",
    tags: []const TagResult = &.{},
    search_value: []const u8 = "",
    has_untagged: bool = false,
    tags_active: []const feed_types.SqliteId = &.{},
    css_icons_hash: u64 = 0,
};

pub fn is_tag_checked(tag_id: feed_types.SqliteId, tags_checked: []const feed_types.SqliteId) bool {
    return std.mem.findScalar(feed_types.SqliteId, tags_checked, tag_id) != null;
}

const untagged = "[untagged]";

pub const HomeContent = struct {
    next_update_ts: ?i64 = null,
    items: []const feed_types.FeedItemRender = &.{},
    feeds: []const feed_types.Feed = &.{},
    failed_requests: []const feed_types.Feed.ID = &.{},
    cookie_last_item_ts: i64 = 0,
    now_sec: i64,
    display_feed_delete_msg: bool = false,
};

fn has_request_failed(feed_id: feed_types.Feed.ID, failed_requests: []const feed_types.Feed.ID) bool {
    if (std.mem.indexOfScalar(feed_types.Feed.ID, failed_requests, feed_id)) |_| {
        return true;
    }
    return false;
}

const LatestOptions = struct {
    is_new_item: bool = false,
    has_request_failed: bool = false,
    now_sec: i64,
};

const failed_request_msg = "Latest update to this feed failed";

pub fn get_feed_with_id(feed_id: feed_types.Feed.ID, feeds: []const feed_types.Feed) feed_types.Feed {
    for (feeds) |feed| {
        if (feed.feed_id == feed_id) {
            return feed;
        }
    }
    unreachable;
}

pub const TagsContent = struct {
    query_error: ?UrlQueryError = null,
    query_is_success: bool = false,
};

pub const FailedFeedsContent = struct {
    failed_requests: []const Storage.FeedFailedRequestWithID,
};

const title_placeholder = "[no-title]";

pub const FeedAddOpts = struct {
    query_success: ?std.fmt.ParseIntError!u64 = null,
    query_feed_exists: ?std.fmt.ParseIntError!u64 = null,
    query_error: ?UrlQueryError = null,
    input_url: []const u8 = "",
    input_tags: []const u8 = "",
};

pub const FeedPickOpts = struct {
    query_feed_exists: ?std.fmt.ParseIntError!u64 = null,
    query_error: ?UrlQueryError = null,
    input_url: []const u8 = "",
    input_tags: []const u8 = "",
    query_picked_index: u32 = 0,
    query: *@import("httpz").key_value.StringKeyValue,
    writer: *std.Io.Writer,
    is_html_checked: bool = false,
    html_opts: @import("../feed_parse.zig").HtmlOptions,
};

pub fn render_picks(query: *@import("httpz").key_value.StringKeyValue, picked_index: u32, w: *std.Io.Writer) !void {
    var index: u32 = 0;
    for (query.keys, query.values) |key, value| {
        if (std.mem.eql(u8, "url", key)) {
            try PickItem.render(.{ value, index, index == picked_index }, w);
            index += 1;
        }
    }
}

pub const FeedsOpts = struct {
    feeds: []const feed_types.Feed,
    items: []const feed_types.FeedItemRender = &.{},
    failed_requests: []const feed_types.Feed.ID = &.{},
    now_sec: i64 = 0,
    feeds_tags: []const Storage.FeedTag = &.{},
    footer: ?struct {
        base: []const u8,
        prev: ?feed_types.Feed.ID,
        next: feed_types.Feed.ID,
    } = null,
};

const no_title = "[no-text-content]";

fn feed_tags_slice(feed_id: feed_types.Feed.ID, feeds_tags: []const Storage.FeedTag) ?[]const Storage.FeedTag {
    var start: ?usize = null;
    for (feeds_tags, 0..) |feed_tag, i| {
        if (feed_tag.feed_id == feed_id) {
            start = i;
            break;
        }
    }

    if (start) |s| {
        const slice = feeds_tags[s..];
        for (slice[1..], 1..) |feed_tag, i| {
            if (feed_tag.feed_id != feed_id) {
                return slice[0..i];
            }
        }
        return slice[0..];
    }

    return null;
}

fn get_tag_name(tag_id: feed_types.SqliteId, tags: []const TagResult) ?[]const u8 {
    for (tags) |tag| {
        if (tag_id == tag.tag_id) {
            return tag.name;
        }
    }
    return null;
}

fn feed_items_slice(feed_id: feed_types.Feed.ID, items: []const feed_types.FeedItemRender) ?[]const feed_types.FeedItemRender {
    var start: ?usize = null;
    for (items, 0..) |item, i| {
        if (item.feed_id == feed_id) {
            start = i;
            break;
        }
    }

    if (start) |s| {
        const slice = items[s..];
        for (slice[1..], 1..) |item, i| {
            if (item.feed_id != feed_id) {
                return slice[0..i];
            }
        }
        return slice[0..];
    }

    return null;
}

pub const TagEditOpts = struct {
    title: []const u8,
    tag: TagResult,
    query_error: ?UrlQueryError = null,
    query_is_success: bool = false,
};

pub const FeedOpts = struct {
    head_title: []const u8 = "",
    feed: feed_types.Feed,
    feed_items: []const feed_types.FeedItemRender,
    feed_tags: []const feed_types.SqliteId = &.{},
    last_update: ?i64,
    next_update: ?i64,
    now_sec: i64,
    failed_requests: []const Storage.FeedFailedRequest,
    query_success: bool = false,
    query_error: ?UrlQueryError = null,
    html_opts: ?@import("../feed_parse.zig").HtmlOptions = null,
    input_icon_url_or_data: []const u8 = "",
};

const IconIdClass = struct {
    value: feed_types.IconRender.ID,

    pub fn init(icon_id: feed_types.IconRender.ID) ?IconIdClass {
        if (icon_id.is_valid()) {
            return .{ .value = icon_id };
        }
        return null;
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("icon-id-{d}", .{@backingInt(self.value)});
    }
};

pub const Layout = struct {
    fn _render(title: []const u8, nav: Navigation, children: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:53:17
        _ = &title;
        _ = &nav;
        try zt.writeAll(_writer, "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"><meta http-equiv=\"X-UA-Compatible\" content=\"ie=edge\"><title>");
        try zt.writeEscaped(_writer, title); // pages.zt:60:16
        try zt.writeAll(_writer, "</title>");
        if (builtin.mode == .debug) { // pages.zt:61:9
            try zt.writeRaw(_writer, "<script async>" ++ reload_js ++ "</script>"); // pages.zt:62:13
        }
        try zt.writeAll(_writer, "<script>\n            /*! kelpui v1.6.3 | (c) Chris Ferdinandi | http://github.com/cferdinandi/kelp */\n            \"use strict\";\n            (() => {\n              // modules/js/dark-mode-auto.js\n              var prefersDarkMode = window.matchMedia(\"(prefers-color-scheme: dark)\");\n              document.documentElement.classList.toggle(\"dark\", prefersDarkMode.matches);\n              prefersDarkMode.addEventListener(\"change\", (event) => {\n                document.documentElement.classList.toggle(\"dark\", event.matches);\n              });\n            })();\n        </script><link rel=\"stylesheet\" type=\"text/css\"");
        try zt.writeUrlAttr(_writer, "href", get_static_path("main.css")); // pages.zt:77:48
        try zt.writeAll(_writer, "><link rel=\"stylesheet\" type=\"text/css\" href=\"/public/");
        try zt.writeEscaped(_writer, nav.css_icons_hash); // pages.zt:78:48
        try zt.writeAll(_writer, "-icons.css\"><script defer");
        try zt.writeUrlAttr(_writer, "src", get_static_path("main.js")); // pages.zt:79:23
        try zt.writeAll(_writer, "></script><script async type=\"module\"");
        try zt.writeUrlAttr(_writer, "src", get_static_path("relative-time.js")); // pages.zt:80:37
        try zt.writeAll(_writer, "></script></head><body><div>");
        try zt.renderComponent(Nav, .{nav}, _writer); // pages.zt:84:13
        try zt.renderComponent(children, .{}, _writer); // pages.zt:85:13
        try zt.writeAll(_writer, "</div></body></html>");
    }

    fn _signature(_: []const u8, _: Navigation, _: zt.Component) void {} // pages.zt:53:17

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const Nav = struct {
    fn _render(nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:112:14
        _ = &nav;
        try zt.writeAll(_writer, "<header class=\"body-header\"><div class=\"nav\"><h1><a href=\"/\"");
        try zt.writeAttr(_writer, "aria-current", if (std.mem.eql(u8, nav.current_path, "/")) "page" else null); // pages.zt:116:23
        try zt.writeAll(_writer, ">feedgaze</a></h1><nav>");
        for (menu_items) |item| { // pages.zt:119:13
            try zt.writeAll(_writer, "<span>|</span><a href=\"");
            try zt.writeUrlPart(_writer, "", item.path, ""); // pages.zt:121:20
            try zt.writeAll(_writer, "\"");
            try zt.writeAttr(_writer, "aria-current", if (std.mem.eql(u8, nav.current_path, item.path)) "page" else null); // pages.zt:121:39
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, item.name); // pages.zt:121:121
            try zt.writeAll(_writer, "</a>");
        }
        try zt.writeAll(_writer, "</nav></div><details><summary>Filter feeds</summary><div class=\"filter-wrapper\"><form action=\"/feeds\" class=\"stack\"><button aria-hidden=\"true\" style=\"display: none\">Default form action</button><fieldset class=\"tags stack\"><legend>Tags</legend><div class=\"tag-list\"><div class=\"tag\"><input type=\"checkbox\" name=\"untagged\" id=\"untagged\"");
        try zt.writeBoolAttr(_writer, "checked", nav.has_untagged); // pages.zt:136:72
        try zt.writeAll(_writer, "><label class=\"visually-hidden\" for=\"untagged\">");
        try zt.writeEscaped(_writer, untagged); // pages.zt:137:65
        try zt.writeAll(_writer, "</label><a class=\"truncate-1\" href=\"/feeds?untagged=\" title=\"untagged\">");
        try zt.writeEscaped(_writer, untagged); // pages.zt:138:82
        try zt.writeAll(_writer, "</a></div>");
        for (nav.tags) |tag| { // pages.zt:141:15
            try zt.writeAll(_writer, "<div class=\"tag\"><input type=\"checkbox\" name=\"tag\" id=\"tag-id-");
            try zt.writeEscaped(_writer, @backingInt(tag.tag_id)); // pages.zt:143:55
            try zt.writeAll(_writer, "\" value=\"");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:143:93
            try zt.writeAll(_writer, "\"");
            try zt.writeBoolAttr(_writer, "checked", is_tag_checked(tag.tag_id, nav.tags_active)); // pages.zt:143:112
            try zt.writeAll(_writer, "><label class=\"visually-hidden\" for=\"tag-id-");
            try zt.writeEscaped(_writer, @backingInt(tag.tag_id)); // pages.zt:144:52
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:144:91
            try zt.writeAll(_writer, "</label><a class=\"truncate-1\" href=\"/feeds?tag=");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:145:43
            try zt.writeAll(_writer, "\" title=\"");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:145:72
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:145:91
            try zt.writeAll(_writer, "</a></div>");
        }
        try zt.writeAll(_writer, "</div></fieldset><div><button class=\"muted secondary\" name=\"tags-only\">Filter tags only</button></div><div><label class=\"form-heading\" for=\"search_value\">Filter feeds</label><div class=\"input-search-wrapper\"><input type=\"search\" name=\"search\" id=\"search_value\"");
        try zt.writeAttr(_writer, "value", nav.search_value); // pages.zt:153:102
        try zt.writeAll(_writer, "></div><button class=\"form-submit muted primary\">Filter all</button></div></form></div></details><hr></header>");
    }

    fn _signature(_: Navigation) void {} // pages.zt:112:14

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const HomePage__children_0 = struct {
    fn _render(content: HomeContent, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:174:19
        _ = &content;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"content-latest flow\">");
        if (content.display_feed_delete_msg) { // pages.zt:177:13
            try zt.writeAll(_writer, "<div class=\"message\"><p>Feed deleted</p><a href=\"/\">Close message</a></div>");
        }
        try zt.writeAll(_writer, "<header class=\"main-header\"><h2>Latest added</h2>");
        if (content.next_update_ts) |countdown_ts| { // pages.zt:188:17
            try zt.writeAll(_writer, "<div class=\"heading-info\"><relative-time update=\"false\"><p class=\"update-automatic\">Next update <time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{countdown_ts})); // pages.zt:191:75
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(countdown_ts)); // pages.zt:191:132
            try zt.writeAll(_writer, "</time></p><div class=\"update-manual\" hidden><p>Last update was <time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{countdown_ts})); // pages.zt:194:58
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(countdown_ts)); // pages.zt:194:115
            try zt.writeAll(_writer, "</time>.</p><form method=\"POST\" action=\"/update\"><p><button class=\"btn-link\">Check for updates.</button>\n                                    Might take some time.\n                                  </p></form></div></relative-time></div>");
        }
        try zt.writeAll(_writer, "</header>");
        if (content.items.len == 0) { // pages.zt:207:13
            try zt.writeAll(_writer, "<p class=\"callout\">No feed items have been added in the previous 3 days</p>");
        } else {
            try zt.writeAll(_writer, "<relative-time update=\"false\" format-style=\"narrow\" format-numeric=\"always\"><ul class=\"stack list-unstyled\">");
            for (content.items) |item| { // pages.zt:212:17
                try zt.writeAll(_writer, "<li class=\"feed-item\">");
                try zt.renderComponent(FeedItemLatest, .{ item, get_feed_with_id(item.feed_id, content.feeds), LatestOptions{
                    .is_new_item = item.created_timestamp > content.cookie_last_item_ts,
                    .now_sec = content.now_sec,
                    .has_request_failed = has_request_failed(item.feed_id, content.failed_requests),
                } }, _writer); // pages.zt:214:24
                try zt.writeAll(_writer, "</li>");
            }
            try zt.writeAll(_writer, "</ul></relative-time>");
        }
        try zt.writeAll(_writer, "</main>");
    }

    fn _signature(_: HomeContent, _: Navigation) void {} // pages.zt:174:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const HomePage = struct {
    fn _render(content: HomeContent, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:174:19
        _ = &content;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Home - latest added feed items", nav, __children_0 }, _writer); // pages.zt:175:5
    }

    fn _signature(_: HomeContent, _: Navigation) void {} // pages.zt:174:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = HomePage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const FeedItemLatest = struct {
    fn _render(item: feed_types.FeedItemRender, feed: feed_types.Feed, opts: LatestOptions, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:244:25
        _ = &item;
        _ = &feed;
        _ = &opts;
        try zt.writeAll(_writer, "<div class=\"feed-time\">");
        try zt.renderComponent(LatestItemRelativeTime, .{ item.updated_timestamp, opts.now_sec }, _writer); // pages.zt:246:9
        if (opts.is_new_item) { // pages.zt:247:9
            try zt.writeAll(_writer, "<span>new</span>");
        }
        try zt.writeAll(_writer, "</div>");
        try zt.renderComponent(ItemLink, .{item}, _writer); // pages.zt:253:5
        try zt.writeAll(_writer, "<div class=\"item-extra\"><div><a href=\"/feed/");
        try zt.writeEscaped(_writer, @backingInt(feed.feed_id)); // pages.zt:257:16
        try zt.writeAll(_writer, "\" title=\"");
        try zt.writeEscaped(_writer, feed.title); // pages.zt:257:57
        try zt.writeAll(_writer, "\">");
        try zt.writeEscaped(_writer, feed.title); // pages.zt:257:78
        try zt.writeAll(_writer, "</a>");
        if (opts.has_request_failed) { // pages.zt:259:13
            try zt.writeAll(_writer, "<span class=\"mi-start-5xs feed-failed-icon\" title=\"");
            try zt.writeEscaped(_writer, failed_request_msg); // pages.zt:260:61
            try zt.writeAll(_writer, "\"></span><span class=\"visually-hidden\">");
            try zt.writeEscaped(_writer, failed_request_msg); // pages.zt:261:47
            try zt.writeAll(_writer, "</span>");
        }
        try zt.writeAll(_writer, "</div><a class=\"feed-external-url ");
        try zt.writeEscaped(_writer, IconIdClass.init(feed.icon_id)); // pages.zt:266:12
        try zt.writeAll(_writer, "\" href=\"");
        try zt.writeUrlPart(_writer, "", feed.page_url orelse feed.feed_url, ""); // pages.zt:266:71
        try zt.writeAll(_writer, "\" rel=\"noreferrer noopener\"><span>");
        try zt.writeEscaped(_writer, zt.fmt(util.write_url_domain, .{feed.page_url orelse feed.feed_url})); // pages.zt:267:19
        try zt.writeAll(_writer, "</span></a></div>");
    }

    fn _signature(_: feed_types.FeedItemRender, _: feed_types.Feed, _: LatestOptions) void {} // pages.zt:244:25

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const LatestItemRelativeTime = struct {
    fn _render(ts_opt: ?i64, now_sec: i64, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:281:33
        _ = &ts_opt;
        _ = &now_sec;
        if (ts_opt) |ts| { // pages.zt:282:5
            try zt.writeAll(_writer, "<time class=\"");
            try zt.writeEscaped(_writer, util.age_class_from_time(now_sec, ts)); // pages.zt:283:15
            try zt.writeAll(_writer, "\" datetime=\"");
            try zt.writeEscaped(_writer, zt.fmt(util.write_timestamp, .{ts})); // pages.zt:283:63
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, zt.fmt(util.write_display_date, .{ now_sec, ts })); // pages.zt:284:13
            try zt.writeAll(_writer, "</time>");
        } else {
            try zt.writeAll(_writer, "<span class=\"no-date\">&#8212;</span>");
        }
    }

    fn _signature(_: ?i64, _: i64) void {} // pages.zt:281:33

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const TagsPage__children_0 = struct {
    fn _render(content: TagsContent, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:296:19
        _ = &content;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><header class=\"main-header\"><h2>Tags</h2></header>");
        if (content.query_is_success) { // pages.zt:300:11
            try zt.writeAll(_writer, "<p class=\"callout success\">Tag deleted</p>");
        } else if (content.query_error) |query_error| { // pages.zt:302:18
            switch (query_error) { // pages.zt:303:15
                .delete => { // pages.zt:304:19
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Failed to delete tag</p>");
                },
                .missing => { // pages.zt:305:19
                    try zt.writeAll(_writer, "<p class=\"callout warning\">Tag doesn't exist</p>");
                },
                else => { // pages.zt:306:19
                },
            }
        }
        try zt.writeAll(_writer, "<ul class=\"tags-all stack list-unstyled\" role=\"list\">");
        for (nav.tags) |tag| { // pages.zt:313:15
            try zt.writeAll(_writer, "<li class=\"tag-item\"><a class=\"truncate-1\" href=\"/feeds?tag=");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:315:41
            try zt.writeAll(_writer, "\" title=\"");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:315:70
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:315:89
            try zt.writeAll(_writer, "</a><div class=\"tag-actions cluster align-center\"><a href=\"/tag/");
            try zt.writeEscaped(_writer, @backingInt(tag.tag_id)); // pages.zt:318:24
            try zt.writeAll(_writer, "/edit\">Edit</a><form action=\"/tag/");
            try zt.writeEscaped(_writer, @backingInt(tag.tag_id)); // pages.zt:319:27
            try zt.writeAll(_writer, "/delete\" method=\"POST\"><button class=\"btn-link padding-0 danger\" name=\"action\" value=\"delete\">Delete</button></form></div></li>");
        }
        try zt.writeAll(_writer, "</ul></main>");
    }

    fn _signature(_: TagsContent, _: Navigation) void {} // pages.zt:296:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const TagsPage = struct {
    fn _render(content: TagsContent, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:296:19
        _ = &content;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Tags", nav, __children_0 }, _writer); // pages.zt:297:5
    }

    fn _signature(_: TagsContent, _: Navigation) void {} // pages.zt:296:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = TagsPage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const FailedFeedsPage__children_0 = struct {
    fn _render(content: FailedFeedsContent, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:336:26
        _ = &content;
        _ = &nav;
        try zt.writeAll(_writer, "<h2>Failed feed requests</h2>");
        if (content.failed_requests.len == 0) { // pages.zt:339:9
            try zt.writeAll(_writer, "<p>No failed feed requests</p>");
        } else {
            for (content.failed_requests) |failed_request| { // pages.zt:342:13
                try zt.writeAll(_writer, "<section class=\"failed-feed\"><header");
                try zt.writeAttr(_writer, "class", IconIdClass.init(failed_request.icon_id)); // pages.zt:344:29
                try zt.writeAll(_writer, "><h3 class=\"truncate-1\">");
                if (failed_request.page_url) |page_url| { // pages.zt:346:25
                    try zt.writeAll(_writer, "<a href=\"");
                    try zt.writeUrlPart(_writer, "", page_url, ""); // pages.zt:347:32
                    try zt.writeAll(_writer, "\" title=\"");
                    try zt.writeEscaped(_writer, failed_request.title orelse title_placeholder); // pages.zt:347:50
                    try zt.writeAll(_writer, "\">");
                    try zt.writeEscaped(_writer, failed_request.title orelse title_placeholder); // pages.zt:348:33
                    try zt.writeAll(_writer, "</a>");
                } else {
                    try zt.writeEscaped(_writer, failed_request.title orelse title_placeholder); // pages.zt:351:29
                }
                try zt.writeAll(_writer, "</h3><a class=\"one-line\" href=\"");
                try zt.writeUrlPart(_writer, "", failed_request.feed_url, ""); // pages.zt:354:45
                try zt.writeAll(_writer, "\">Feed link</a><a href=\"/feed/");
                try zt.writeEscaped(_writer, @backingInt(failed_request.feed_id)); // pages.zt:355:28
                try zt.writeAll(_writer, "\">Edit</a></header><p>Latest error <time datetime=\"");
                try zt.writeEscaped(_writer, zt.fmt(util.write_timestamp, .{failed_request.utc_sec})); // pages.zt:358:43
                try zt.writeAll(_writer, "\">\n                        (");
                try zt.writeEscaped(_writer, util.date_readable(failed_request.utc_sec)); // pages.zt:359:26
                try zt.writeAll(_writer, ")</time>: ");
                try zt.writeEscaped(_writer, failed_request.reason); // pages.zt:359:80
                try zt.writeAll(_writer, "</p></section>");
            }
        }
    }

    fn _signature(_: FailedFeedsContent, _: Navigation) void {} // pages.zt:336:26

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const FailedFeedsPage = struct {
    fn _render(content: FailedFeedsContent, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:336:26
        _ = &content;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Failed feed requests", nav, __children_0 }, _writer); // pages.zt:337:5
    }

    fn _signature(_: FailedFeedsContent, _: Navigation) void {} // pages.zt:336:26

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = FailedFeedsPage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const FeedAddPage__children_0 = struct {
    fn _render(opts: FeedAddOpts, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:375:22
        _ = &opts;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><header class=\"main-header\"><h2>Add feed</h2></header>");
        if (opts.query_success) |success_err| { // pages.zt:379:13
            if (success_err) |feed_id| { // pages.zt:380:17
                try zt.writeAll(_writer, "<p class=\"callout success\">Feed added.\n                        <a href=\"/feed/");
                try zt.writeEscaped(_writer, feed_id); // pages.zt:382:28
                try zt.writeAll(_writer, "\">Got to feed page</a>.\n                    </p>");
            } else |err| { // pages.zt:384:19
                try zt.writeAll(_writer, "<p>Please provide valid feed ID. Error: ");
                try zt.writeEscaped(_writer, err); // pages.zt:385:61
                try zt.writeAll(_writer, "</p>");
            }
        } else if (opts.query_feed_exists) |feed_exists_err| { // pages.zt:387:20
            if (feed_exists_err) |feed_id| { // pages.zt:388:17
                try zt.writeAll(_writer, "<p>Feed already exists.\n                        <a href=\"/feed/");
                try zt.writeEscaped(_writer, feed_id); // pages.zt:390:28
                try zt.writeAll(_writer, "\">Got to feed page</a>.\n                    </p>");
            } else |err| { // pages.zt:392:19
                try zt.writeAll(_writer, "<p>Please provide valid feed ID. Error: ");
                try zt.writeEscaped(_writer, err); // pages.zt:393:61
                try zt.writeAll(_writer, "</p>");
            }
        } else if (opts.query_error) |err_enum| { // pages.zt:395:20
            switch (err_enum) { // pages.zt:396:18
                .invalid_url => { // pages.zt:397:22
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Enter valid feed/page link</p>");
                },
                .url_missing => { // pages.zt:398:22
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Fill in feed/page link</p>");
                },
                else => { // pages.zt:399:22
                },
            }
        }
        try zt.writeAll(_writer, "<form action=\"/feed/add\" method=\"POST\" class=\"flow\" style=\"--flow-space: var(--size-4xl)\"><div><div><label for=\"input-url\">Feed/Page link</label></div><input type=\"text\" class=\"char-len-l\" id=\"input-url\" name=\"input-url\" value=\"");
        try zt.writeEscaped(_writer, opts.input_url); // pages.zt:408:91
        try zt.writeAll(_writer, "\"></div><div><div class=\"label-wrapper\"><label for=\"input-tags\">Tags (optional)</label><em>Tags are comma separated</em></div><input type=\"text\" class=\"char-len-m\" id=\"input-tags\" name=\"input-tags\" value=\"");
        try zt.writeEscaped(_writer, opts.input_tags); // pages.zt:416:93
        try zt.writeAll(_writer, "\"></div><button class=\"primary muted\">Add new feed</button></form></main>");
    }

    fn _signature(_: FeedAddOpts, _: Navigation) void {} // pages.zt:375:22

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const FeedAddPage = struct {
    fn _render(opts: FeedAddOpts, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:375:22
        _ = &opts;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Add feed", nav, __children_0 }, _writer); // pages.zt:376:5
    }

    fn _signature(_: FeedAddOpts, _: Navigation) void {} // pages.zt:375:22

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = FeedAddPage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const FeedPickPage__children_0 = struct {
    fn _render(opts: FeedPickOpts, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:437:23
        _ = &opts;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><header class=\"main-header\"><h2>Pick feed</h2></header>");
        if (opts.query_feed_exists) |result_err| { // pages.zt:441:13
            if (result_err) |feed_id| { // pages.zt:442:17
                try zt.writeAll(_writer, "<p class=\"callout\">Feed already exists.\n                        <a href=\"/feed/");
                try zt.writeEscaped(_writer, feed_id); // pages.zt:444:28
                try zt.writeAll(_writer, "\">Got to feed page</a>.\n                    </p>");
            } else |err| { // pages.zt:446:19
                try zt.writeAll(_writer, "<p class=\"callout danger\">Invalid feed ID. Error: ");
                try zt.writeEscaped(_writer, err); // pages.zt:447:71
                try zt.writeAll(_writer, "</p>");
            }
        } else if (opts.query_error) |query_error| { // pages.zt:449:20
            switch (query_error) { // pages.zt:450:17
                .invalid_url => { // pages.zt:451:21
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Enter valid url.</p>");
                },
                .url_missing => { // pages.zt:452:21
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Pick feed option.</p>");
                },
                .empty_selector => { // pages.zt:453:21
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Fill in 'Feed item selector'.</p>");
                },
                .pick_url => { // pages.zt:454:21
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Pick one of the feed options.</p>");
                },
                .fetch_failed => { // pages.zt:455:21
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Failed to fetch feed.</p>");
                },
                .fetch_status_not_ok => { // pages.zt:456:21
                    try zt.writeAll(_writer, "<p class=\"callout danger\"><span>Failed to fetch feed because returned status code wasn't 200 (OK).</span>");
                    if (opts.query.get("fetch_status")) |status| { // pages.zt:459:29
                        try zt.writeAll(_writer, "\n                                Returned status code: ");
                        try zt.writeEscaped(_writer, status); // pages.zt:460:55
                    }
                    try zt.writeAll(_writer, "</p>");
                },
                else => { // pages.zt:465:21
                },
            }
        }
        try zt.writeAll(_writer, "<form action=\"/feed/pick\" method=\"POST\" class=\"flow\" style=\"--flow-space: var(--size-4xl)\"><div><label>Feed/Page link</label><input class=\"char-len-l\" type=\"text\" readonly name=\"input-url\"");
        try zt.writeAttr(_writer, "value", opts.input_url); // pages.zt:474:85
        try zt.writeAll(_writer, "></div><fieldset><legend>Pick feed to add</legend><ul class=\"list-unstyled margin-end-0\">");
        try zt.writeEscaped(_writer, try render_picks(opts.query, opts.query_picked_index, opts.writer)); // pages.zt:481:25
        try zt.writeAll(_writer, "<li><label for=\"url-html\"><input type=\"radio\" id=\"url-html\" name=\"url-picked\" value=\"html\"");
        try zt.writeBoolAttr(_writer, "checked", opts.is_html_checked); // pages.zt:484:98
        try zt.writeAll(_writer, ">\n                                Html as feed\n                            </label></li></ul><div><noscript><p class=\"callout\">\n                                Fill these fields if you picked \"Html as feed\".\n                            </p></noscript><div class=\"html-feed-inputs flow\"><div><label for=\"feed-container\">Html item selector</label><input type=\"text\" id=\"feed-container\" name=\"selector-container\" value=\"");
        try zt.writeEscaped(_writer, opts.html_opts.selector_container); // pages.zt:498:98
        try zt.writeAll(_writer, "\"></div><p class=\"callout\">Rest of the fields are optional. And selector fields root (starting point) is feed item selector.</p><div><div class=\"label-wrapper\"><label for=\"feed-link\">Html link selector (optional)</label><em>Fallback is &lt;a&gt; href value</em></div><input type=\"text\" id=\"feed-link\" name=\"selector-link\" value=\"");
        try zt.writeEscaped(_writer, opts.html_opts.selector_link); // pages.zt:508:88
        try zt.writeAll(_writer, "\"></div><div><div class=\"label-wrapper\"><label for=\"feed-heading\">Html heading selector (optional)</label><em>Fallback are headings (&lt;h1&gt;-&lt;h6&gt;). After that whole item container's text will be used.</em></div><input type=\"text\" id=\"feed-heading\" name=\"selector-heading\" value=\"");
        try zt.writeEscaped(_writer, opts.html_opts.selector_heading); // pages.zt:516:94
        try zt.writeAll(_writer, "\"></div><div><div class=\"label-wrapper\"><label for=\"feed-date\">Html date selector (optional)</label><em>Fallback is &lt;time&gt.</em></div><input type=\"text\" id=\"feed-date\" name=\"selector-date\" value=\"");
        try zt.writeEscaped(_writer, opts.html_opts.selector_date); // pages.zt:524:88
        try zt.writeAll(_writer, "\"></div><div><div class=\"label-wrapper\"><label for=\"feed-date-format\">Html date format (optional)</label><em>Fallback is date format that &lt;time&gt; uses.</em></div><input type=\"text\" id=\"feed-date-format\" name=\"feed-date-format\" value=\"");
        try zt.writeEscaped(_writer, opts.html_opts.date_format); // pages.zt:532:98
        try zt.writeAll(_writer, "\"></div></div></div></fieldset><div><div class=\"label-wrapper\"><label for=\"input-tags\">Tags (optional)</label><em>Tags are comma separated</em></div><input class=\"char-len-m\" id=\"input-tags\" name=\"input-tags\" value=\"");
        try zt.writeEscaped(_writer, opts.input_tags); // pages.zt:544:81
        try zt.writeAll(_writer, "\"></div><div class=\"form-actions\"><button class=\"primary muted\">Add new feed</button><a href=\"/feed/add\">Cancel</a></div></form></main>");
    }

    fn _signature(_: FeedPickOpts, _: Navigation) void {} // pages.zt:437:23

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const FeedPickPage = struct {
    fn _render(opts: FeedPickOpts, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:437:23
        _ = &opts;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Pick feed", nav, __children_0 }, _writer); // pages.zt:438:5
    }

    fn _signature(_: FeedPickOpts, _: Navigation) void {} // pages.zt:437:23

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = FeedPickPage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const PickItem = struct {
    fn _render(value: []const u8, index: u32, is_checked: bool, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:566:19
        _ = &value;
        _ = &index;
        _ = &is_checked;
        try zt.writeAll(_writer, "<li><input type=\"hidden\" name=\"url\" value=\"");
        try zt.writeEscaped(_writer, value); // pages.zt:568:41
        try zt.writeAll(_writer, "\"><label for=\"url-");
        try zt.writeEscaped(_writer, index); // pages.zt:569:16
        try zt.writeAll(_writer, "\"><input type=\"radio\" id=\"url-");
        try zt.writeEscaped(_writer, index); // pages.zt:570:33
        try zt.writeAll(_writer, "\" name=\"url-picked\" value=\"");
        try zt.writeEscaped(_writer, value); // pages.zt:570:68
        try zt.writeAll(_writer, "\"");
        try zt.writeBoolAttr(_writer, "checked", is_checked); // pages.zt:570:84
        try zt.writeAll(_writer, ">");
        try zt.writeEscaped(_writer, value); // pages.zt:571:13
        try zt.writeAll(_writer, "</label></li>");
    }

    fn _signature(_: []const u8, _: u32, _: bool) void {} // pages.zt:566:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const FeedsPage__children_0 = struct {
    fn _render(opts: FeedsOpts, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:589:20
        _ = &opts;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><header class=\"main-header\"><h2>Feeds</h2><div class=\"main-actions cluster\"><button class=\"outline js-expand-all\">Expand all</button><button class=\"outline js-collapse-all\">Collapse all</button></div></header>");
        if (opts.feeds.len > 0) { // pages.zt:600:13
            try zt.writeAll(_writer, "<div class=\"flow\">");
            for (opts.feeds) |feed| { // pages.zt:602:17
                try zt.writeAll(_writer, "<article class=\"feed\"><header><div class=\"feed-header-top ");
                try zt.writeEscaped(_writer, IconIdClass.init(feed.icon_id)); // pages.zt:605:34
                try zt.writeAll(_writer, "\">");
                if (feed.page_url) |page_url| { // pages.zt:607:29
                    try zt.writeAll(_writer, "<a class=\"feed-title truncate-1\" href=\"");
                    try zt.writeUrlPart(_writer, "", page_url, ""); // pages.zt:608:66
                    try zt.writeAll(_writer, "\" rel=\"noreferrer noopener\" title=\"");
                    try zt.writeEscaped(_writer, feed.title orelse title_placeholder); // pages.zt:608:110
                    try zt.writeAll(_writer, "\">");
                    try zt.writeEscaped(_writer, feed.title orelse title_placeholder); // pages.zt:608:156
                    try zt.writeAll(_writer, "</a>");
                } else {
                    try zt.writeAll(_writer, "<p class=\"feed-title truncate-1\">");
                    try zt.writeEscaped(_writer, feed.title orelse title_placeholder); // pages.zt:610:66
                    try zt.writeAll(_writer, "</p>");
                }
                try zt.renderComponent(LatestItemRelativeTime, .{ feed.updated_timestamp, opts.now_sec }, _writer); // pages.zt:613:33
                try zt.writeAll(_writer, "<a class=\"feed-edit\" href=\"/feed/");
                try zt.writeEscaped(_writer, @backingInt(feed.feed_id)); // pages.zt:614:54
                try zt.writeAll(_writer, "\">Edit feed</a></div>");
                if (std.mem.indexOfScalar(feed_types.Feed.ID, opts.failed_requests, feed.feed_id)) |_| { // pages.zt:617:29
                    try zt.writeAll(_writer, "<p class=\"feed-failed-msg feed-failed-icon\">Last update failed</p>");
                }
                if (feed_tags_slice(feed.feed_id, opts.feeds_tags)) |feed_tags| { // pages.zt:623:29
                    try zt.writeAll(_writer, "<div class=\"feed-tags\"><ul class=\"list-unstyled\" aria-label=\"Feed tags\">");
                    for (feed_tags) |feed_tag| { // pages.zt:626:37
                        if (get_tag_name(feed_tag.tag_id, nav.tags)) |tag_name| { // pages.zt:627:41
                            try zt.writeAll(_writer, "<li><a class=\"badge\" href=\"/feeds?tag=");
                            try zt.writeEscaped(_writer, tag_name); // pages.zt:629:66
                            try zt.writeAll(_writer, "\" title=\"");
                            try zt.writeEscaped(_writer, tag_name); // pages.zt:629:95
                            try zt.writeAll(_writer, "\">");
                            try zt.writeEscaped(_writer, tag_name); // pages.zt:629:114
                            try zt.writeAll(_writer, "</a></li>");
                        }
                    }
                    try zt.writeAll(_writer, "</ul></div>");
                }
                try zt.writeAll(_writer, "</header>");
                if (feed_items_slice(feed.feed_id, opts.items)) |items| { // pages.zt:640:25
                    try zt.writeAll(_writer, "<relative-time update=\"false\" format-style=\"narrow\" format-numeric=\"always\"><ul class=\"stack list-unstyled\">");
                    for (items) |item| { // pages.zt:643:33
                        try zt.writeAll(_writer, "<li class=\"feed-item\">");
                        try zt.renderComponent(LatestItemRelativeTime, .{ item.updated_timestamp, opts.now_sec }, _writer); // pages.zt:645:41
                        try zt.renderComponent(ItemLink, .{item}, _writer); // pages.zt:646:41
                        try zt.writeAll(_writer, "</li>");
                    }
                    try zt.writeAll(_writer, "</ul></relative-time>");
                } else {
                    try zt.writeAll(_writer, "<p class=\"callout size-xs\">Feed has no items.</p>");
                }
                try zt.writeAll(_writer, "<footer class=\"feed-footer\"><button class=\"outline js-feed-item-toggle\" aria-expanded=\"true\"><span class=\"toggle-expand\">Expand</span><span class=\"toggle-collapse\">Collapse</span></button></footer></article>");
            }
            if (opts.footer) |f| { // pages.zt:664:17
                try zt.writeAll(_writer, "<footer class=\"main-footer\"><hr>");
                if (f.prev) |prev| { // pages.zt:667:25
                    try zt.writeAll(_writer, "<a href=\"");
                    try zt.writeUrlPart(_writer, "", f.base, "&before="); // pages.zt:668:32
                    try zt.writeUrlPart(_writer, "&before=", @backingInt(prev), ""); // pages.zt:668:32
                    try zt.writeAll(_writer, "\">Previous</a>");
                }
                try zt.writeAll(_writer, "<a href=\"");
                try zt.writeUrlPart(_writer, "", f.base, "&after="); // pages.zt:671:28
                try zt.writeUrlPart(_writer, "&after=", @backingInt(f.next), ""); // pages.zt:671:28
                try zt.writeAll(_writer, "\">Next</a></footer>");
            }
            try zt.writeAll(_writer, "</div>");
        } else {
            try zt.writeAll(_writer, "<p class=\"callout\">No feeds to show</p>");
        }
        try zt.writeAll(_writer, "</main>");
    }

    fn _signature(_: FeedsOpts, _: Navigation) void {} // pages.zt:589:20

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const FeedsPage = struct {
    fn _render(opts: FeedsOpts, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:589:20
        _ = &opts;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Feeds", nav, __children_0 }, _writer); // pages.zt:590:5
    }

    fn _signature(_: FeedsOpts, _: Navigation) void {} // pages.zt:589:20

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = FeedsPage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const ItemLink = struct {
    fn _render(item: feed_types.FeedItemRender, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:687:19
        _ = &item;
        if (item.link) |link| { // pages.zt:688:5
            try zt.writeAll(_writer, "<a href=\"");
            try zt.writeUrlPart(_writer, "", link, ""); // pages.zt:689:12
            try zt.writeAll(_writer, "\" class=\"item-link truncate-2\"");
            try zt.writeAttr(_writer, "title", if (item.title.len > 0) item.title else no_title); // pages.zt:689:55
            try zt.writeAll(_writer, " rel=\"noreferrer noopener\">");
            if (item.title.len > 0) { // pages.zt:690:14
                try zt.writeEscaped(_writer, item.title); // pages.zt:690:38
            } else {
                try zt.writeEscaped(_writer, no_title); // pages.zt:690:54
            }
            try zt.writeAll(_writer, "</a>");
        } else {
            try zt.writeAll(_writer, "<p class=\"truncate-2\"");
            try zt.writeAttr(_writer, "title", if (item.title.len > 0) item.title else no_title); // pages.zt:693:31
            try zt.writeAll(_writer, ">");
            if (item.title.len > 0) { // pages.zt:694:14
                try zt.writeEscaped(_writer, item.title); // pages.zt:694:38
            } else {
                try zt.writeEscaped(_writer, no_title); // pages.zt:694:54
            }
            try zt.writeAll(_writer, "</p>");
        }
    }

    fn _signature(_: feed_types.FeedItemRender) void {} // pages.zt:687:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const TagEditPage__children_0 = struct {
    fn _render(opts: TagEditOpts, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:759:22
        _ = &opts;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><h2>");
        try zt.writeEscaped(_writer, opts.title); // pages.zt:762:15
        try zt.writeAll(_writer, "</h2>");
        if (opts.query_is_success) { // pages.zt:763:11
            try zt.writeAll(_writer, "<div><p class=\"callout success\">Changes saved</p></div>");
        } else if (opts.query_error == .invalid_form) { // pages.zt:765:18
            try zt.writeAll(_writer, "<div><p class=\"callout danger\">Invalid form</p></div>");
        }
        try zt.writeAll(_writer, "<form class=\"flow\" method=\"post\"><div><div><label for=\"tag-name\">Tag name</label></div><input class=\"char-len-s\" type=\"text\" id=\"tag-name\" name=\"tag-name\"");
        try zt.writeAttr(_writer, "value", opts.tag.name); // pages.zt:776:83
        try zt.writeAll(_writer, "></div><input type=\"hidden\" name=\"tag-id\"");
        try zt.writeAttr(_writer, "value", @backingInt(opts.tag.tag_id)); // pages.zt:778:48
        try zt.writeAll(_writer, "><div><button class=\"muted primary\" name=\"action\" value=\"save\">Save changes</button></div><button class=\"outline danger\" name=\"action\" value=\"delete\">Delete tag</button></form></main>");
    }

    fn _signature(_: TagEditOpts, _: Navigation) void {} // pages.zt:759:22

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const TagEditPage = struct {
    fn _render(opts: TagEditOpts, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:759:22
        _ = &opts;
        _ = &nav;
        try zt.renderComponent(Layout, .{ opts.title, nav, __children_0 }, _writer); // pages.zt:760:5
    }

    fn _signature(_: TagEditOpts, _: Navigation) void {} // pages.zt:759:22

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = TagEditPage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const FeedPage__children_0 = struct {
    fn _render(opts: FeedOpts, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:819:19
        _ = &opts;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><h2");
        try zt.writeAttr(_writer, "class", IconIdClass.init(opts.feed.icon_id)); // pages.zt:822:17
        try zt.writeAll(_writer, ">");
        if (opts.feed.title) |title| { // pages.zt:823:17
            try zt.writeEscaped(_writer, title); // pages.zt:824:21
        } else {
            try zt.writeEscaped(_writer, title_placeholder); // pages.zt:826:21
        }
        try zt.writeAll(_writer, "</h2><div class=\"feed-info flow\"><p>");
        if (opts.feed.page_url) |page_url| { // pages.zt:832:21
            try zt.writeAll(_writer, "\n                        Page link: <a");
            try zt.writeUrlAttr(_writer, "href", page_url); // pages.zt:833:39
            try zt.writeAll(_writer, " class=\"inline-block\" rel=\"noreferrer noopener\">");
            try zt.writeEscaped(_writer, page_url); // pages.zt:833:102
            try zt.writeAll(_writer, "</a>");
        } else {
            try zt.writeAll(_writer, "\n                        Page link: [no-url]\n                    ");
        }
        try zt.writeAll(_writer, "</p><p>Feed link: <a");
        try zt.writeUrlAttr(_writer, "href", opts.feed.feed_url); // pages.zt:838:34
        try zt.writeAll(_writer, " rel=\"noreferrer noopener\">");
        try zt.writeEscaped(_writer, opts.feed.feed_url); // pages.zt:838:86
        try zt.writeAll(_writer, "</a></p>");
        if (opts.last_update) |last_update| { // pages.zt:840:17
            try zt.writeAll(_writer, "<p>Last update was\n                        <em><relative-time update=\"false\"><time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{last_update})); // pages.zt:843:35
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(last_update)); // pages.zt:843:91
            try zt.writeAll(_writer, "</time></relative-time></em></p>");
        }
        if (opts.next_update) |next_update| { // pages.zt:850:17
            try zt.writeAll(_writer, "<p>Next update\n                        <em><relative-time update=\"false\"><time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{next_update})); // pages.zt:853:35
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(next_update)); // pages.zt:853:91
            try zt.writeAll(_writer, "</time></relative-time></em></p>");
        } else {
            try zt.writeAll(_writer, "<p class=\"callout warning\">This feed's updating is disabled. Failed to fetch feed too many times.</p>");
        }
        if (opts.failed_requests.len > 0) { // pages.zt:864:17
            try zt.writeAll(_writer, "<table class=\"table-striped\"><caption>Failed request(s)</caption><tr><th>Date</th><th>Error</th></tr>");
            for (opts.failed_requests) |failed| { // pages.zt:872:21
                try zt.writeAll(_writer, "<tr><td><time");
                try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{failed.utc_sec})); // pages.zt:875:41
                try zt.writeAll(_writer, ">");
                try zt.writeEscaped(_writer, util.date_readable(failed.utc_sec)); // pages.zt:875:100
                try zt.writeAll(_writer, "</time></td><td>");
                try zt.writeEscaped(_writer, failed.reason); // pages.zt:877:35
                try zt.writeAll(_writer, "</td></tr>");
            }
            try zt.writeAll(_writer, "</table>");
        }
        if (opts.query_success) { // pages.zt:885:17
            try zt.writeAll(_writer, "<p class=\"callout success\">Feed changes saved</p>");
        }
        if (opts.query_error) |err_enum| { // pages.zt:891:17
            try zt.writeAll(_writer, "<p class=\"callout danger\">");
            switch (err_enum) { // pages.zt:893:21
                .delete => { // pages.zt:894:25
                    try zt.writeAll(_writer, "Failed to delete feed");
                },
                .feed => { // pages.zt:895:25
                    try zt.writeAll(_writer, "Failed to update feed");
                },
                .html => { // pages.zt:896:25
                    try zt.writeAll(_writer, "Failed to update feed html fields");
                },
                .item_selector => { // pages.zt:897:25
                    try zt.writeAll(_writer, "Fill in 'Feed item selector' field");
                },
                .icon_too_large => { // pages.zt:898:25
                    try zt.writeAll(_writer, "'Icon url' size is too big. Allowed max size ");
                    try zt.writeEscaped(_writer, Server.icon_input_max_size); // pages.zt:898:90
                },
                .unknown => { // pages.zt:899:25
                    try zt.writeAll(_writer, "Failed to save feed changes");
                },
                else => { // pages.zt:900:25
                },
            }
            try zt.writeAll(_writer, "</p>");
        }
        try zt.writeAll(_writer, "<h3>Edit feed</h3><form class=\"flow\" method=\"POST\"><div><div><label for=\"title\">Feed title</label></div><input class=\"char-len-l\" type=\"text\" id=\"title\" name=\"title\"");
        try zt.writeAttr(_writer, "value", opts.feed.title orelse ""); // pages.zt:911:85
        try zt.writeAll(_writer, "></div><div><div><label for=\"page_url\">Page link</label></div><input type=\"text\" id=\"page_url\" name=\"page_url\"");
        try zt.writeAttr(_writer, "value", opts.feed.page_url); // pages.zt:915:72
        try zt.writeAll(_writer, "></div><div><div><label for=\"icon_url\">Icon link or data</label></div><input type=\"text\" id=\"icon_url\" name=\"icon_url\"");
        try zt.writeAttr(_writer, "value", opts.input_icon_url_or_data); // pages.zt:919:72
        try zt.writeAll(_writer, "></div>");
        if (opts.html_opts) |html_opts| { // pages.zt:922:21
            try zt.writeAll(_writer, "<fieldset class=\"flow\"><legend>Html 'feed' options</legend><div><div><label for=\"html-item-selector\">Feed item selector</label></div><input class=\"char-len-s\" type=\"text\"");
            try zt.writeAttr(_writer, "value", html_opts.selector_container); // pages.zt:927:71
            try zt.writeAll(_writer, " name=\"html-item-selector\" id=\"html-item-selector\"></div><div><div><label for=\"html-link-selector\">Feed item link selector</label></div><input class=\"char-len-s\" type=\"text\"");
            try zt.writeAttr(_writer, "value", html_opts.selector_link); // pages.zt:932:71
            try zt.writeAll(_writer, " name=\"html-link-selector\" id=\"html-link-selector\"></div><div><div><label for=\"html-title-selector\">Feed item link selector</label></div><input class=\"char-len-s\" type=\"text\"");
            try zt.writeAttr(_writer, "value", html_opts.selector_heading); // pages.zt:937:71
            try zt.writeAll(_writer, " name=\"html-title-selector\" id=\"html-title-selector\"></div><div><div><label for=\"html-date-selector\">Feed item link selector</label></div><input class=\"char-len-s\" type=\"text\"");
            try zt.writeAttr(_writer, "value", html_opts.selector_date); // pages.zt:942:71
            try zt.writeAll(_writer, " name=\"html-date-selector\" id=\"html-date-selector\"></div><div><div><label for=\"html-date-format\">Date format</label></div><input class=\"char-len-s\" type=\"text\"");
            try zt.writeAttr(_writer, "value", html_opts.date_format); // pages.zt:947:71
            try zt.writeAll(_writer, " name=\"html-date-format\" id=\"html-date-format\"></div></fieldset>");
        }
        try zt.writeAll(_writer, "<fieldset><legend>Tags</legend><div class=\"feed-tag-list\">");
        for (nav.tags) |tag| { // pages.zt:957:25
            try zt.writeAll(_writer, "<label for=\"tag-edit-");
            try zt.writeEscaped(_writer, @backingInt(tag.tag_id)); // pages.zt:958:36
            try zt.writeAll(_writer, "\"><input type=\"checkbox\" name=\"tag\" id=\"tag-edit-");
            try zt.writeEscaped(_writer, @backingInt(tag.tag_id)); // pages.zt:959:67
            try zt.writeAll(_writer, "\" value=\"");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:959:107
            try zt.writeAll(_writer, "\"");
            try zt.writeBoolAttr(_writer, "checked", is_tag_checked(tag.tag_id, opts.feed_tags)); // pages.zt:959:126
            try zt.writeAll(_writer, "><span class=\"truncate-1\" title=\"");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:960:58
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:960:77
            try zt.writeAll(_writer, "</span></label>");
        }
        try zt.writeAll(_writer, "</div></fieldset><div class=\"form-input\"><div><label for=\"new_tags\">New tags</label><em>Tags are comma separated</em></div><input type=\"text\" id=\"new_tags\" name=\"new_tags\"></div><div><button class=\"muted primary\" name=\"action\" value=\"save\">Save feed changes</button></div><div><button class=\"outline danger\" name=\"action\" value=\"delete\">Delete feed</button></div></form></div><h3>Feed items</h3>");
        if (opts.feed_items.len == 0) { // pages.zt:984:13
            try zt.writeAll(_writer, "<p class=\"callout\">No feeds items in this feed.</p>");
        } else {
            try zt.writeAll(_writer, "<relative-time update=\"false\" format-style=\"narrow\" format-numeric=\"always\"><ul class=\"stack list-unstyled\">");
            for (opts.feed_items) |item| { // pages.zt:989:21
                try zt.writeAll(_writer, "<li class=\"feed-item\">");
                try zt.renderComponent(LatestItemRelativeTime, .{ item.updated_timestamp, opts.now_sec }, _writer); // pages.zt:991:29
                try zt.renderComponent(ItemLink, .{item}, _writer); // pages.zt:992:29
                try zt.writeAll(_writer, "</li>");
            }
            try zt.writeAll(_writer, "</ul></relative-time>");
        }
        try zt.writeAll(_writer, "</main>");
    }

    fn _signature(_: FeedOpts, _: Navigation) void {} // pages.zt:819:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @call(.always_inline, _render, args ++ .{_writer});
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

pub const FeedPage = struct {
    fn _render(opts: FeedOpts, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:819:19
        _ = &opts;
        _ = &nav;
        try zt.renderComponent(Layout, .{ opts.head_title, nav, __children_0 }, _writer); // pages.zt:820:5
    }

    fn _signature(_: FeedOpts, _: Navigation) void {} // pages.zt:819:19

    pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));

    pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const __children_0 = FeedPage__children_0.bind(&args);
        return @call(.always_inline, _render, args ++ .{ __children_0, _writer });
    }

    pub fn bind(args: *const Args) zt.Component {
        return .{
            .ptr = @ptrCast(args),
            .renderFn = struct {
                fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);
                }
            }.f,
        };
    }
};

const std = @import("std");
const zt = @import("zt");

// AUTO-GENERATED FROM pages.zt - DO NOT EDIT
