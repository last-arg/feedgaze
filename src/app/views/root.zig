const std = @import("std");
const jetzig = @import("jetzig");

pub const layout = "base";

pub fn index(request: *jetzig.Request, data: *jetzig.Data) !jetzig.View {
    var root = try data.object();
    try root.put("message", data.string("Welcome to Jetzig!"));
    try root.put("custom_number", data.integer(customFunction(100, 200, 300)));

    for (request.segments.items) |seg| {
        std.debug.print("seg: |{s}|\n", .{seg});
    }

    const p = try request.params();
    std.debug.print("p: {any}\n", .{p.get("search_value")});


    try request.response.headers.append("x-example-header", "example header value");

    return request.render(.ok);
}

fn customFunction(a: i32, b: i32, c: i32) i32 {
    return a + b + c;
}
