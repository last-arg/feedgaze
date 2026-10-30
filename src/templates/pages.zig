const util = @import("../util.zig");
const builtin = @import("builtin");
const feed_types = @import("../feed_types.zig");
const IconManage = @import("../server.zig").IconManage;
const Storage = @import("../storage.zig").Storage;
const UrlQueryError = @import("../server.zig").UrlQueryError;
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

pub const static_files_map = .{
    .{ .filename = "main.css", .hash = hash_static_file("../server/dist/main.css") },
    .{ .filename = "main.js", .hash = hash_static_file("../server/dist/main.js") },
    .{ .filename = "relative-time.js", .hash = hash_static_file("../server/dist/relative-time.js") },
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

const menu_items = [_]struct { path: []const u8, name: []const u8 }{
    .{ .path = "/feeds", .name = "Feeds" },
    .{ .path = "/tags", .name = "Tags" },
    .{ .path = "/feed/add", .name = "Add feed" },
    .{ .path = "/failed-requests", .name = "Failed feed requests" },
};

pub const Navigation = struct {
    current_path: []const u8 = "/",
    tags: []const []const u8 = &.{},
};

pub fn tag_is_checked(tag: []const u8, tags_checked: []const []const u8) bool {
    for (tags_checked) |tag_checked| {
        if (std.mem.eql(u8, tag, tag_checked)) {
            return true;
        }
    }

    return false;
}

pub const HomeContent = struct { next_update_ts: ?i64 = null, items: []const feed_types.FeedItemRender = &.{}, feeds: []const feed_types.Feed = &.{}, failed_requests: []const feed_types.Feed.ID = &.{}, cookie_last_item_ts: i64 = 0, now_sec: i64, icon_manage: *IconManage };

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
    tag_ids: []const TagResult = &.{},
    query_error: ?UrlQueryError = null,
    query_is_success: bool = false,
};

pub const FailedFeedsContent = struct {
    failed_requests: []const Storage.FeedFailedRequestWithID,
    icon_manage: *IconManage,
};

const title_placeholder = "[no-title]";

pub const FeedAddOpts = struct {
    query_success: ?std.fmt.ParseIntError!u64 = null,
    query_feed_exists: ?std.fmt.ParseIntError!u64 = null,
    query_error: ?UrlQueryError = null,
    input_url: []const u8 = "",
    input_tags: []const u8 = "",
};

pub const Layout = struct {
    fn _render(title: []const u8, nav: Navigation, children: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:50:17
        _ = &title;
        _ = &nav;
        try zt.writeAll(_writer, "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"><meta http-equiv=\"X-UA-Compatible\" content=\"ie=edge\"><title>");
        try zt.writeEscaped(_writer, title); // pages.zt:57:16
        try zt.writeAll(_writer, "</title><script>\n            /*! kelpui v1.6.3 | (c) Chris Ferdinandi | http://github.com/cferdinandi/kelp */\n            \"use strict\";\n            (() => {\n              // modules/js/dark-mode-auto.js\n              var prefersDarkMode = window.matchMedia(\"(prefers-color-scheme: dark)\");\n              document.documentElement.classList.toggle(\"dark\", prefersDarkMode.matches);\n              prefersDarkMode.addEventListener(\"change\", (event) => {\n                document.documentElement.classList.toggle(\"dark\", event.matches);\n              });\n            })();\n        </script><link rel=\"stylesheet\" type=\"text/css\" href=\"");
        try zt.writeUrlPart(_writer, "", get_static_path("main.css"), ""); // pages.zt:71:48
        try zt.writeAll(_writer, "\"><script defer src=\"");
        try zt.writeUrlPart(_writer, "", get_static_path("main.js"), ""); // pages.zt:72:23
        try zt.writeAll(_writer, "\"></script><script async type=\"module\" src=\"");
        try zt.writeUrlPart(_writer, "", get_static_path("relative-time.js"), ""); // pages.zt:73:37
        try zt.writeAll(_writer, "\"></script></head><body><div>");
        try zt.renderComponent(Nav, .{nav}, _writer); // pages.zt:77:13
        try zt.renderComponent(children, .{}, _writer); // pages.zt:78:13
        try zt.writeAll(_writer, "</div></body></html>");
    }

    fn _signature(_: []const u8, _: Navigation, _: zt.Component) void {} // pages.zt:50:17

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
    fn _render(nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:106:14
        _ = &nav;
        try zt.writeAll(_writer, "<header class=\"body-header\"><div class=\"nav\"><h1><a href=\"/\"");
        try zt.writeAttr(_writer, "aria-current", if (std.mem.eql(u8, nav.current_path, "/")) "page" else null); // pages.zt:110:23
        try zt.writeAll(_writer, ">feedgaze</a></h1><nav>");
        for (menu_items) |item| { // pages.zt:113:13
            try zt.writeAll(_writer, "<span>|</span><a href=\"");
            try zt.writeUrlPart(_writer, "", item.path, ""); // pages.zt:115:20
            try zt.writeAll(_writer, "\"");
            try zt.writeAttr(_writer, "aria-current", if (std.mem.eql(u8, nav.current_path, item.path)) "page" else null); // pages.zt:115:39
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, item.name); // pages.zt:115:121
            try zt.writeAll(_writer, "</a>");
        }
        try zt.writeAll(_writer, "</nav></div><details><summary>Filter feeds</summary><div class=\"filter-wrapper\"><form action=\"/feeds\" class=\"stack\"><button aria-hidden=\"true\" style=\"display: none\">Default form action</button><fieldset class=\"tags stack\"><legend>Tags</legend><div class=\"tag-list\">");
        for (nav.tags, 0..) |tag, index| { // pages.zt:129:17
            try zt.writeAll(_writer, "<div class=\"tag\"><input type=\"checkbox\" name=\"tag\" id=\"tag-id-");
            try zt.writeEscaped(_writer, index); // pages.zt:131:57
            try zt.writeAll(_writer, "\" value=\"");
            try zt.writeEscaped(_writer, tag); // pages.zt:131:77
            try zt.writeAll(_writer, "\"><label class=\"visually-hidden\" for=\"tag-id-");
            try zt.writeEscaped(_writer, index); // pages.zt:132:54
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, tag); // pages.zt:132:75
            try zt.writeAll(_writer, "</label></div>");
        }
        try zt.writeAll(_writer, "</div></fieldset><div><button class=\"muted secondary\" name=\"tags-only\">Filter tags only</button></div><div><label class=\"form-heading\" for=\"search_value\">Filter feeds</label><div class=\"input-search-wrapper\"><input type=\"search\" name=\"search\" id=\"search_value\" value=\"\"></div><button class=\"form-submit muted primary\">Filter all</button></div></form></div></details><hr></header>");
    }

    fn _signature(_: Navigation) void {} // pages.zt:106:14

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
    fn _render(content: HomeContent, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:161:19
        _ = &content;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"content-latest flow\"><header class=\"main-header\"><h2>Latest added</h2>");
        if (content.next_update_ts) |countdown_ts| { // pages.zt:166:17
            try zt.writeAll(_writer, "<div class=\"heading-info\"><relative-time update=\"false\"><p class=\"update-automatic\">Next update <time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{countdown_ts})); // pages.zt:169:75
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(countdown_ts)); // pages.zt:169:132
            try zt.writeAll(_writer, "</time></p><div class=\"update-manual\" hidden><p>Last update was <time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{countdown_ts})); // pages.zt:172:58
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(countdown_ts)); // pages.zt:172:115
            try zt.writeAll(_writer, "</time>.</p><form method=\"POST\" action=\"/update\"><p><button class=\"btn-link\">Check for updates.</button>\n                                    Might take some time.\n                                  </p></form></div></relative-time></div>");
        }
        try zt.writeAll(_writer, "</header>");
        if (content.items.len == 0) { // pages.zt:185:13
            try zt.writeAll(_writer, "<p class=\"callout\">No feed items have been added in the previous 3 days</p>");
        } else {
            try zt.writeAll(_writer, "<relative-time update=\"false\" format-style=\"narrow\" format-numeric=\"always\"><ul class=\"stack list-unstyled\">");
            for (content.items) |item| { // pages.zt:190:17
                try zt.writeAll(_writer, "<li class=\"feed-item\">");
                try zt.renderComponent(FeedItemLatest, .{ item, get_feed_with_id(item.feed_id, content.feeds), content.icon_manage, LatestOptions{
                    .is_new_item = item.created_timestamp > content.cookie_last_item_ts,
                    .now_sec = content.now_sec,
                    .has_request_failed = has_request_failed(item.feed_id, content.failed_requests),
                } }, _writer); // pages.zt:192:24
                try zt.writeAll(_writer, "</li>");
            }
            try zt.writeAll(_writer, "</ul></relative-time>");
        }
        try zt.writeAll(_writer, "</main>");
    }

    fn _signature(_: HomeContent, _: Navigation) void {} // pages.zt:161:19

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
    fn _render(content: HomeContent, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:161:19
        _ = &content;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Home - latest added feed items", nav, __children_0 }, _writer); // pages.zt:162:5
    }

    fn _signature(_: HomeContent, _: Navigation) void {} // pages.zt:161:19

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
    fn _render(item: feed_types.FeedItemRender, feed: feed_types.Feed, icon_manage: *IconManage, opts: LatestOptions, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:222:25
        _ = &item;
        _ = &feed;
        _ = &icon_manage;
        _ = &opts;
        if (opts.is_new_item) { // pages.zt:223:5
            try zt.writeAll(_writer, "<div class=\"feed-time\">");
            try zt.renderComponent(LatestItemRelativeTime, .{ item.updated_timestamp, opts.now_sec }, _writer); // pages.zt:225:13
            try zt.writeAll(_writer, "<span>new</span></div>");
        } else {
            try zt.renderComponent(LatestItemRelativeTime, .{ item.updated_timestamp, opts.now_sec }, _writer); // pages.zt:229:9
        }
        if (item.link) |link| { // pages.zt:232:5
            try zt.writeAll(_writer, "<a href=\"");
            try zt.writeUrlPart(_writer, "", link, ""); // pages.zt:233:12
            try zt.writeAll(_writer, "\" class=\"item-link truncate-2\" title=\"");
            try zt.writeEscaped(_writer, item.title); // pages.zt:233:55
            try zt.writeAll(_writer, "\" rel=\"noreferrer noopener\">");
            try zt.writeEscaped(_writer, item.title); // pages.zt:233:102
            try zt.writeAll(_writer, "</a>");
        } else {
            try zt.writeAll(_writer, "<p class=\"truncate-2\" title=\"");
            try zt.writeEscaped(_writer, item.title); // pages.zt:235:31
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, item.link); // pages.zt:235:52
            try zt.writeAll(_writer, "</p>");
        }
        try zt.writeAll(_writer, "<div class=\"item-extra\"><div><a href=\"/feed/");
        try zt.writeEscaped(_writer, @backingInt(feed.feed_id)); // pages.zt:240:16
        try zt.writeAll(_writer, "\" title=\"");
        try zt.writeEscaped(_writer, feed.title); // pages.zt:240:57
        try zt.writeAll(_writer, "\">");
        try zt.writeEscaped(_writer, feed.title); // pages.zt:240:78
        try zt.writeAll(_writer, "</a>");
        if (opts.has_request_failed) { // pages.zt:242:13
            try zt.writeAll(_writer, "<span class=\"mi-start-5xs feed-failed-icon\" title=\"");
            try zt.writeEscaped(_writer, failed_request_msg); // pages.zt:243:61
            try zt.writeAll(_writer, "\"></span><span class=\"visually-hidden\">");
            try zt.writeEscaped(_writer, failed_request_msg); // pages.zt:244:47
            try zt.writeAll(_writer, "</span>");
        }
        try zt.writeAll(_writer, "</div><a class=\"feed-external-url\" href=\"");
        try zt.writeUrlPart(_writer, "", feed.page_url orelse feed.feed_url, ""); // pages.zt:249:38
        try zt.writeAll(_writer, "\" rel=\"noreferrer noopener\">");
        if (feed.icon_id.is_valid()) { // pages.zt:250:13
            if (icon_manage.get_icon_info(feed.icon_id)) |info| { // pages.zt:251:17
                try zt.writeAll(_writer, "<img class=\"feed-icon\" src=\"/icons/");
                try zt.writeEscaped(_writer, info.hash); // pages.zt:252:44
                try zt.writeEscaped(_writer, info.file_type); // pages.zt:252:44
                try zt.writeAll(_writer, "\" alt=\"\" aria-hidden=\"true\">");
            }
        }
        try zt.writeAll(_writer, "<span>");
        try zt.writeEscaped(_writer, zt.fmt(util.write_url_domain, .{feed.page_url orelse feed.feed_url})); // pages.zt:259:19
        try zt.writeAll(_writer, "</span></a></div>");
    }

    fn _signature(_: feed_types.FeedItemRender, _: feed_types.Feed, _: *IconManage, _: LatestOptions) void {} // pages.zt:222:25

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
    fn _render(ts_opt: ?i64, now_sec: i64, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:273:33
        _ = &ts_opt;
        _ = &now_sec;
        if (ts_opt) |ts| { // pages.zt:274:5
            try zt.writeAll(_writer, "<time class=\"");
            try zt.writeEscaped(_writer, util.age_class_from_time(now_sec, ts)); // pages.zt:275:15
            try zt.writeAll(_writer, "\" datetime=\"");
            try zt.writeEscaped(_writer, zt.fmt(util.write_timestamp, .{ts})); // pages.zt:275:63
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, zt.fmt(util.write_display_date, .{ now_sec, ts })); // pages.zt:276:13
            try zt.writeAll(_writer, "</time>");
        } else {
            try zt.writeAll(_writer, "<span class=\"no-date\">&#8212;</span>");
        }
    }

    fn _signature(_: ?i64, _: i64) void {} // pages.zt:273:33

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
    fn _render(content: TagsContent, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:289:19
        _ = &content;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><header class=\"main-header\"><h2>Tags</h2></header>");
        if (content.query_is_success) { // pages.zt:293:11
            try zt.writeAll(_writer, "<p class=\"callout success\">Tag deleted</p>");
        } else if (content.query_error) |query_error| { // pages.zt:295:18
            switch (query_error) { // pages.zt:296:15
                .delete => { // pages.zt:297:19
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Failed to delete tag</p>");
                },
                .missing => { // pages.zt:298:19
                    try zt.writeAll(_writer, "<p class=\"callout warning\">Tag doesn't exist</p>");
                },
                else => { // pages.zt:299:19
                },
            }
        }
        try zt.writeAll(_writer, "<ul class=\"tags-all stack list-unstyled\" role=\"list\">");
        for (content.tag_ids) |tag| { // pages.zt:306:15
            try zt.writeAll(_writer, "<li class=\"tag-item\"><a class=\"truncate-1\" href=\"/feeds?tag=");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:308:41
            try zt.writeAll(_writer, "\" title=\"");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:308:70
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, tag.name); // pages.zt:308:89
            try zt.writeAll(_writer, "</a><div class=\"tag-actions cluster align-center\"><a href=\"/tag/{@backingInt(tag.tag_id)}/edit\">Edit</a><form action=\"/tag/");
            try zt.writeEscaped(_writer, @backingInt(tag.tag_id)); // pages.zt:312:27
            try zt.writeAll(_writer, "/delete\" method=\"POST\"><button class=\"btn-link padding-0 danger\" name=\"action\" value=\"delete\">Delete</button></form></div></li>");
        }
        try zt.writeAll(_writer, "</ul></main>");
    }

    fn _signature(_: TagsContent, _: Navigation) void {} // pages.zt:289:19

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
    fn _render(content: TagsContent, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:289:19
        _ = &content;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Tags", nav, __children_0 }, _writer); // pages.zt:290:5
    }

    fn _signature(_: TagsContent, _: Navigation) void {} // pages.zt:289:19

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
    fn _render(content: FailedFeedsContent, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:330:26
        _ = &content;
        _ = &nav;
        try zt.writeAll(_writer, "<h2>Failed feed requests</h2>");
        if (content.failed_requests.len == 0) { // pages.zt:333:9
            try zt.writeAll(_writer, "<p>No failed feed requests</p>");
        } else {
            for (content.failed_requests) |failed_request| { // pages.zt:336:13
                try zt.writeAll(_writer, "<section class=\"failed-feed\"><header>");
                if (failed_request.icon_id.is_valid()) { // pages.zt:339:25
                    if (content.icon_manage.get_icon_info(failed_request.icon_id)) |info| { // pages.zt:340:29
                        try zt.writeAll(_writer, "<img class=\"feed-icon\" src=\"/icons/");
                        try zt.writeEscaped(_writer, info.hash); // pages.zt:341:56
                        try zt.writeEscaped(_writer, info.file_type); // pages.zt:341:56
                        try zt.writeAll(_writer, "\" alt=\"\" aria-hidden=\"true\">");
                    }
                }
                try zt.writeAll(_writer, "<h3 class=\"truncate-1\">");
                if (failed_request.page_url) |page_url| { // pages.zt:349:25
                    try zt.writeAll(_writer, "<a href=\"");
                    try zt.writeUrlPart(_writer, "", page_url, ""); // pages.zt:350:32
                    try zt.writeAll(_writer, "\" title=\"");
                    try zt.writeEscaped(_writer, failed_request.title orelse title_placeholder); // pages.zt:350:50
                    try zt.writeAll(_writer, "\">");
                    try zt.writeEscaped(_writer, failed_request.title orelse title_placeholder); // pages.zt:351:33
                    try zt.writeAll(_writer, "</a>");
                } else {
                    try zt.writeEscaped(_writer, failed_request.title orelse title_placeholder); // pages.zt:354:29
                }
                try zt.writeAll(_writer, "</h3><a class=\"one-line\" href=\"{failed_request.feed_url}\">Feed link</a><a href=\"/feed/{@backingInt(failed_request.feed_id)}\">Edit</a></header><p>Latest error <time datetime=\"");
                try zt.writeEscaped(_writer, zt.fmt(util.write_timestamp, .{failed_request.utc_sec})); // pages.zt:361:43
                try zt.writeAll(_writer, "\">\n                        (");
                try zt.writeEscaped(_writer, util.date_readable(failed_request.utc_sec)); // pages.zt:362:26
                try zt.writeAll(_writer, ")</time>: ");
                try zt.writeEscaped(_writer, failed_request.reason); // pages.zt:362:80
                try zt.writeAll(_writer, "</p></section>");
            }
        }
    }

    fn _signature(_: FailedFeedsContent, _: Navigation) void {} // pages.zt:330:26

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
    fn _render(content: FailedFeedsContent, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:330:26
        _ = &content;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Failed feed requests", nav, __children_0 }, _writer); // pages.zt:331:5
    }

    fn _signature(_: FailedFeedsContent, _: Navigation) void {} // pages.zt:330:26

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
    fn _render(opts: FeedAddOpts, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:378:22
        _ = &opts;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"flow\"><header class=\"main-header\"><h2>Add feed</h2></header>");
        if (opts.query_success) |success_err| { // pages.zt:382:13
            if (success_err) |feed_id| { // pages.zt:383:17
                try zt.writeAll(_writer, "<p class=\"callout success\">Feed added.\n                        <a href=\"/feed/");
                try zt.writeEscaped(_writer, feed_id); // pages.zt:385:28
                try zt.writeAll(_writer, "\">Got to feed page</a>.\n                    </p>");
            } else |err| { // pages.zt:387:19
                try zt.writeAll(_writer, "<p>Please provide valid feed ID. Error: ");
                try zt.writeEscaped(_writer, err); // pages.zt:388:61
                try zt.writeAll(_writer, "</p>");
            }
        } else if (opts.query_feed_exists) |feed_exists_err| { // pages.zt:390:20
            if (feed_exists_err) |feed_id| { // pages.zt:391:17
                try zt.writeAll(_writer, "<p>Feed already exists.\n                        <a href=\"/feed/");
                try zt.writeEscaped(_writer, feed_id); // pages.zt:393:28
                try zt.writeAll(_writer, "\">Got to feed page</a>.\n                    </p>");
            } else |err| { // pages.zt:395:19
                try zt.writeAll(_writer, "<p>Please provide valid feed ID. Error: ");
                try zt.writeEscaped(_writer, err); // pages.zt:396:61
                try zt.writeAll(_writer, "</p>");
            }
        } else if (opts.query_error) |err_enum| { // pages.zt:398:20
            switch (err_enum) { // pages.zt:399:18
                .invalid_url => { // pages.zt:400:22
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Enter valid feed/page link</p>");
                },
                .url_missing => { // pages.zt:401:22
                    try zt.writeAll(_writer, "<p class=\"callout danger\">Fill in feed/page link</p>");
                },
                else => { // pages.zt:402:22
                },
            }
        }
        try zt.writeAll(_writer, "<form action=\"/feed/add\" method=\"POST\" class=\"flow\" style=\"--flow-space: var(--size-4xl)\"><div><div><label for=\"input-url\">Feed/Page link</label></div><input type=\"text\" class=\"char-len-l\" id=\"input-url\" name=\"input-url\" value=\"");
        try zt.writeEscaped(_writer, opts.input_url); // pages.zt:411:91
        try zt.writeAll(_writer, "\"></div><div><div class=\"label-wrapper\"><label for=\"input-tags\">Tags (optional)</label><em>Tags are comma separated</em></div><input type=\"text\" class=\"char-len-m\" id=\"input-tags\" name=\"input-tags\" value=\"");
        try zt.writeEscaped(_writer, opts.input_tags); // pages.zt:419:93
        try zt.writeAll(_writer, "\"></div><button class=\"primary muted\">Add new feed</button></form></main>");
    }

    fn _signature(_: FeedAddOpts, _: Navigation) void {} // pages.zt:378:22

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
    fn _render(opts: FeedAddOpts, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:378:22
        _ = &opts;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Add feed", nav, __children_0 }, _writer); // pages.zt:379:5
    }

    fn _signature(_: FeedAddOpts, _: Navigation) void {} // pages.zt:378:22

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

const std = @import("std");
const zt = @import("zt");

// AUTO-GENERATED FROM pages.zt - DO NOT EDIT
