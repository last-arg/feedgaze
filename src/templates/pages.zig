const util = @import("../util.zig");
const builtin = @import("builtin");
const feed_types = @import("../feed_types.zig");
const IconManage = @import("../server.zig").IconManage;

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

pub const Layout = struct {
    fn _render(title: []const u8, nav: Navigation, children: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:47:17
        _ = &title;
        _ = &nav;
        try zt.writeAll(_writer, "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"><meta http-equiv=\"X-UA-Compatible\" content=\"ie=edge\"><title>");
        try zt.writeEscaped(_writer, title); // pages.zt:54:16
        try zt.writeAll(_writer, "</title><script>\n            /*! kelpui v1.6.3 | (c) Chris Ferdinandi | http://github.com/cferdinandi/kelp */\n            \"use strict\";\n            (() => {\n              // modules/js/dark-mode-auto.js\n              var prefersDarkMode = window.matchMedia(\"(prefers-color-scheme: dark)\");\n              document.documentElement.classList.toggle(\"dark\", prefersDarkMode.matches);\n              prefersDarkMode.addEventListener(\"change\", (event) => {\n                document.documentElement.classList.toggle(\"dark\", event.matches);\n              });\n            })();\n        </script><link rel=\"stylesheet\" type=\"text/css\" href=\"");
        try zt.writeUrlPart(_writer, "", get_static_path("main.css"), ""); // pages.zt:68:48
        try zt.writeAll(_writer, "\"><script defer src=\"");
        try zt.writeUrlPart(_writer, "", get_static_path("main.js"), ""); // pages.zt:69:23
        try zt.writeAll(_writer, "\"></script><script async type=\"module\" src=\"");
        try zt.writeUrlPart(_writer, "", get_static_path("relative-time.js"), ""); // pages.zt:70:37
        try zt.writeAll(_writer, "\"></script></head><body><div>");
        try zt.renderComponent(Nav, .{nav}, _writer); // pages.zt:74:13
        try zt.renderComponent(children, .{}, _writer); // pages.zt:75:13
        try zt.writeAll(_writer, "</div></body></html>");
    }

    fn _signature(_: []const u8, _: Navigation, _: zt.Component) void {} // pages.zt:47:17

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
    fn _render(nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:103:14
        _ = &nav;
        try zt.writeAll(_writer, "<header class=\"body-header\"><div class=\"nav\"><h1><a href=\"/\"");
        try zt.writeAttr(_writer, "aria-current", if (std.mem.eql(u8, nav.current_path, "/")) "page" else null); // pages.zt:107:23
        try zt.writeAll(_writer, ">feedgaze</a></h1><nav>");
        for (menu_items) |item| { // pages.zt:110:13
            try zt.writeAll(_writer, "<span>|</span><a href=\"");
            try zt.writeUrlPart(_writer, "", item.path, ""); // pages.zt:112:20
            try zt.writeAll(_writer, "\"");
            try zt.writeAttr(_writer, "aria-current", if (std.mem.eql(u8, nav.current_path, item.path)) "page" else null); // pages.zt:112:39
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, item.name); // pages.zt:112:121
            try zt.writeAll(_writer, "</a>");
        }
        try zt.writeAll(_writer, "</nav></div><details><summary>Filter feeds</summary><div class=\"filter-wrapper\"><form action=\"/feeds\" class=\"stack\"><button aria-hidden=\"true\" style=\"display: none\">Default form action</button><fieldset class=\"tags stack\"><legend>Tags</legend><div class=\"tag-list\">");
        for (nav.tags, 0..) |tag, index| { // pages.zt:126:17
            try zt.writeAll(_writer, "<div class=\"tag\"><input type=\"checkbox\" name=\"tag\" id=\"tag-id-");
            try zt.writeEscaped(_writer, index); // pages.zt:128:57
            try zt.writeAll(_writer, "\" value=\"");
            try zt.writeEscaped(_writer, tag); // pages.zt:128:77
            try zt.writeAll(_writer, "\"><label class=\"visually-hidden\" for=\"tag-id-");
            try zt.writeEscaped(_writer, index); // pages.zt:129:54
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, tag); // pages.zt:129:75
            try zt.writeAll(_writer, "</label></div>");
        }
        try zt.writeAll(_writer, "</div></fieldset><div><button class=\"muted secondary\" name=\"tags-only\">Filter tags only</button></div><div><label class=\"form-heading\" for=\"search_value\">Filter feeds</label><div class=\"input-search-wrapper\"><input type=\"search\" name=\"search\" id=\"search_value\" value=\"\"></div><button class=\"form-submit muted primary\">Filter all</button></div></form></div></details><hr></header>");
    }

    fn _signature(_: Navigation) void {} // pages.zt:103:14

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
    fn _render(content: HomeContent, nav: Navigation, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:158:19
        _ = &content;
        _ = &nav;
        try zt.writeAll(_writer, "<main class=\"content-latest flow\"><header class=\"main-header\"><h2>Latest added</h2>");
        if (content.next_update_ts) |countdown_ts| { // pages.zt:163:17
            try zt.writeAll(_writer, "<div class=\"heading-info\">");
            try zt.writeEscaped(_writer, util.date_readable(countdown_ts)); // pages.zt:165:25
            try zt.writeAll(_writer, "<relative-time update=\"false\"><p class=\"update-automatic\">Next update <time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{countdown_ts})); // pages.zt:167:75
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(countdown_ts)); // pages.zt:167:132
            try zt.writeAll(_writer, "</time></p><div class=\"update-manual\" hidden><p>Last update was <time");
            try zt.writeAttr(_writer, "datetime", zt.fmt(util.write_timestamp, .{countdown_ts})); // pages.zt:170:58
            try zt.writeAll(_writer, ">");
            try zt.writeEscaped(_writer, util.date_readable(countdown_ts)); // pages.zt:170:115
            try zt.writeAll(_writer, "</time>.</p><form method=\"POST\" action=\"/update\"><p><button class=\"btn-link\">Check for updates.</button>\n                                    Might take some time.\n                                  </p></form></div></relative-time></div>");
        }
        try zt.writeAll(_writer, "</header>");
        if (content.items.len == 0) { // pages.zt:183:13
            try zt.writeAll(_writer, "<p class=\"callout\">No feed items have been added in the previous 3 days</p>");
        } else {
            try zt.writeAll(_writer, "<relative-time update=\"false\" format-style=\"narrow\" format-numeric=\"always\"><ul class=\"stack list-unstyled\">");
            for (content.items) |item| { // pages.zt:188:17
                try zt.writeAll(_writer, "<li class=\"feed-item\">");
                try zt.renderComponent(FeedItemLatest, .{ item, get_feed_with_id(item.feed_id, content.feeds), content.icon_manage, LatestOptions{
                    .is_new_item = item.created_timestamp > content.cookie_last_item_ts,
                    .now_sec = content.now_sec,
                    .has_request_failed = has_request_failed(item.feed_id, content.failed_requests),
                } }, _writer); // pages.zt:190:24
                try zt.writeAll(_writer, "</li>");
            }
            try zt.writeAll(_writer, "</ul></relative-time>");
        }
        try zt.writeAll(_writer, "</main>");
    }

    fn _signature(_: HomeContent, _: Navigation) void {} // pages.zt:158:19

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
    fn _render(content: HomeContent, nav: Navigation, __children_0: zt.Component, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:158:19
        _ = &content;
        _ = &nav;
        try zt.renderComponent(Layout, .{ "Home - latest added feed items", nav, __children_0 }, _writer); // pages.zt:159:5
    }

    fn _signature(_: HomeContent, _: Navigation) void {} // pages.zt:158:19

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
    fn _render(item: feed_types.FeedItemRender, feed: feed_types.Feed, icon_manage: *IconManage, opts: LatestOptions, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:220:25
        _ = &item;
        _ = &feed;
        _ = &icon_manage;
        _ = &opts;
        if (opts.is_new_item) { // pages.zt:221:5
            try zt.writeAll(_writer, "<div class=\"feed-time\">");
            try zt.renderComponent(LatestItemRelativeTime, .{ item.updated_timestamp, opts.now_sec }, _writer); // pages.zt:223:13
            try zt.writeAll(_writer, "<span>new</span></div>");
        } else {
            try zt.renderComponent(LatestItemRelativeTime, .{ item.updated_timestamp, opts.now_sec }, _writer); // pages.zt:227:9
        }
        if (item.link) |link| { // pages.zt:230:5
            try zt.writeAll(_writer, "<a href=\"");
            try zt.writeUrlPart(_writer, "", link, ""); // pages.zt:231:12
            try zt.writeAll(_writer, "\" class=\"item-link truncate-2\" title=\"");
            try zt.writeEscaped(_writer, item.title); // pages.zt:231:55
            try zt.writeAll(_writer, "\" rel=\"noreferrer noopener\">");
            try zt.writeEscaped(_writer, item.title); // pages.zt:231:102
            try zt.writeAll(_writer, "</a>");
        } else {
            try zt.writeAll(_writer, "<p class=\"truncate-2\" title=\"");
            try zt.writeEscaped(_writer, item.title); // pages.zt:233:31
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, item.link); // pages.zt:233:52
            try zt.writeAll(_writer, "</p>");
        }
        try zt.writeAll(_writer, "<div class=\"item-extra\"><div><a href=\"/feed/");
        try zt.writeEscaped(_writer, @backingInt(feed.feed_id)); // pages.zt:238:16
        try zt.writeAll(_writer, "\" title=\"");
        try zt.writeEscaped(_writer, feed.title); // pages.zt:238:57
        try zt.writeAll(_writer, "\">");
        try zt.writeEscaped(_writer, feed.title); // pages.zt:238:78
        try zt.writeAll(_writer, "</a>");
        if (opts.has_request_failed) { // pages.zt:240:13
            try zt.writeAll(_writer, "<span class=\"mi-start-5xs feed-failed-icon\" title=\"");
            try zt.writeEscaped(_writer, failed_request_msg); // pages.zt:241:61
            try zt.writeAll(_writer, "\"></span><span class=\"visually-hidden\">");
            try zt.writeEscaped(_writer, failed_request_msg); // pages.zt:242:47
            try zt.writeAll(_writer, "</span>");
        }
        try zt.writeAll(_writer, "</div><a class=\"feed-external-url\" href=\"");
        try zt.writeUrlPart(_writer, "", feed.page_url orelse feed.feed_url, ""); // pages.zt:247:38
        try zt.writeAll(_writer, "\" rel=\"noreferrer noopener\">");
        if (feed.icon_id.is_valid()) { // pages.zt:248:13
            if (icon_manage.get_icon_info(feed.icon_id)) |info| { // pages.zt:249:17
                try zt.writeAll(_writer, "<img class=\"feed-icon\" src=\"/icons/");
                try zt.writeEscaped(_writer, info.hash); // pages.zt:250:44
                try zt.writeEscaped(_writer, info.file_type); // pages.zt:250:44
                try zt.writeAll(_writer, "\" alt=\"\" aria-hidden=\"true\">");
            }
        }
        try zt.writeAll(_writer, "<span>");
        try zt.writeEscaped(_writer, zt.fmt(util.write_url_domain, .{feed.page_url orelse feed.feed_url})); // pages.zt:257:19
        try zt.writeAll(_writer, "</span></a></div>");
    }

    fn _signature(_: feed_types.FeedItemRender, _: feed_types.Feed, _: *IconManage, _: LatestOptions) void {} // pages.zt:220:25

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
    fn _render(ts_opt: ?i64, now_sec: i64, _writer: *std.Io.Writer) std.Io.Writer.Error!void { // pages.zt:271:33
        _ = &ts_opt;
        _ = &now_sec;
        if (ts_opt) |ts| { // pages.zt:272:5
            try zt.writeAll(_writer, "<time class=\"");
            try zt.writeEscaped(_writer, util.age_class_from_time(now_sec, ts)); // pages.zt:273:15
            try zt.writeAll(_writer, "\" datetime=\"");
            try zt.writeEscaped(_writer, zt.fmt(util.write_timestamp, .{ts})); // pages.zt:273:63
            try zt.writeAll(_writer, "\">");
            try zt.writeEscaped(_writer, zt.fmt(util.write_display_date, .{ now_sec, ts })); // pages.zt:274:13
            try zt.writeAll(_writer, "</time>");
        } else {
            try zt.writeAll(_writer, "<span class=\"no-date\">&#8212;</span>");
        }
    }

    fn _signature(_: ?i64, _: i64) void {} // pages.zt:271:33

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

const std = @import("std");
const zt = @import("zt");

// AUTO-GENERATED FROM pages.zt - DO NOT EDIT
