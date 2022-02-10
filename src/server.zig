const std = @import("std");
const routez = @import("routez");
const Server = routez.Server;
const Request = routez.Request;
const Response = routez.Response;
const print = std.debug.print;
const allocator = std.heap.page_allocator;
const Address = std.net.Address;

pub const io_mode = .evented;

pub fn init() !void {
    print("run server\n", .{});
    var server = Server.init(
        allocator,
        .{},
        .{
            routez.all("/", indexHandler),
            // routez.get("/about", aboutHandler),
        },
    );
    // NOTE: For faster debugging
    server.server.reuse_address = true;
    var addr = try Address.parseIp("127.0.0.1", 8282);
    try server.listen(addr);
}

fn indexHandler(req: Request, res: Response) !void {
    _ = req;
    try res.write("Hello index\n");
}
