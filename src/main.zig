const std = @import("std");
const log = std.log;
const sql = @import("sqlite");
const mem = std.mem;
const print = std.debug.print;
const process = std.process;
const Allocator = std.mem.Allocator;
const command = @import("cli.zig");
const Storage = @import("feed_db.zig").Storage;
const Cli = command.Cli;
const clap = @import("clap");
const known_folders = @import("known-folders");

pub const log_level = std.log.Level.debug;
pub const known_folders_config = .{
    .xdg_on_mac = true,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const base_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const help_flag = newFlag("help", false, "Display this help and exit.");
    const db_flag = newFlag("db", "~/.config/feedgaze/feedgaze.sqlite", "Point to sqlite database location.");
    const url_flag = newFlag("url", true, "Apply action only to url feeds.");
    const local_flag = newFlag("local", true, "Apply action only to local feeds.");
    const force_flag = newFlag("force", false, "Force update all feeds.");
    const default_flag = newFlag("default", @as(u32, 1), "Auto pick a item from printed out list.");
    const add_tags_flag = newFlag("tags", "", "Add (comma separated) tags to feed .");

    // TODO: new command 'tag'
    // --id <feed's id>
    // --location <feed's location>
    // current flags: help, db,

    comptime var base_flags = [_]FlagOpt{ help_flag, url_flag, local_flag, db_flag };
    const BaseCmd = FlagSet(&base_flags);
    comptime var remove_flags = base_flags ++ [_]FlagOpt{default_flag};
    const RemoveCmd = FlagSet(&remove_flags);
    comptime var add_flags = remove_flags ++ [_]FlagOpt{add_tags_flag};
    const AddCmd = FlagSet(&add_flags);
    comptime var update_flags = base_flags ++ [_]FlagOpt{force_flag};
    const UpdateCmd = FlagSet(&update_flags);

    var args = try process.argsAlloc(std.testing.allocator);
    defer process.argsFree(std.testing.allocator, args);

    if (args.len == 1) {
        log.err("No subcommand entered.", .{});
        try usage();
        return error.MissingSubCommand;
    }

    const Subcommand = enum { add, update, remove, search, clean, @"print-feeds", @"print-items" };
    const subcmd_str = args[1];
    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_str) orelse {
        // Check if help flag was entered
        comptime var root_flags = [_]FlagOpt{help_flag};
        var root_cmd = FlagSet(&root_flags){};
        try root_cmd.parse(args[1..]);
        if (root_cmd.getFlag("help")) |f| {
            if (try f.getBoolean()) {
                try usage();
                return;
            }
        }
        log.err("Unknown subcommand '{s}'.", .{subcmd_str});
        return error.UnknownSubCommand;
    };

    const cmds = struct {
        add: AddCmd = .{ .name = "add" },
        update: UpdateCmd = .{ .name = "update" },
        remove: RemoveCmd = .{ .name = "remove" },
        search: BaseCmd = .{ .name = "search" },
        clean: BaseCmd = .{ .name = "clean" },
        @"print-feeds": BaseCmd = .{ .name = "print-feeds" },
        @"print-items": BaseCmd = .{ .name = "print-items" },
    }{};

    var args_rest: [][:0]const u8 = undefined;
    var db_path: []const u8 = undefined;
    var has_help = false;
    var tags: []const u8 = "";
    var cli_options = command.CliOptions{};

    // Parse input args
    inline for (comptime std.meta.fieldNames(Subcommand)) |name| {
        if (subcmd == std.meta.stringToEnum(Subcommand, name)) {
            var cmd = @field(cmds, name);
            try cmd.parse(args[2..]);
            args_rest = cmd.args;
            if (cmd.getFlag("help")) |f| {
                has_help = try f.getBoolean();
            }
            db_path = try cmd.getFlag("db").?.getString();
            var local = cli_options.local;
            if (cmd.getFlag("local")) |value| {
                local = try value.getBoolean();
            }
            var url = cli_options.url;
            if (cmd.getFlag("url")) |value| {
                url = try value.getBoolean();
            }
            cli_options.url = url or !local;
            cli_options.local = local or !url;
            if (cmd.getFlag("force")) |force| {
                cli_options.force = try force.getBoolean();
            }

            if (cmd.getFlag("default")) |value| {
                cli_options.default = try value.getInt();
            }

            if (cmd.getFlag("default")) |value| {
                cli_options.default = try value.getInt();
            }

            if (cmd.getFlag("tags")) |value| {
                tags = try value.getString();
            }

            // Don't use break, continue, return inside inline loops
            // https://github.com/ziglang/zig/issues/2727
            // https://github.com/ziglang/zig/issues/9524
        }
    }

    if (has_help) {
        try usage();
        return;
    }

    const subcom_input_required = [_]Subcommand{ .add, .remove, .search };
    for (subcom_input_required) |required| {
        if (required == subcmd and args_rest.len == 0) {
            log.err("Subcommand '{s}' requires input(s)", .{subcmd_str});
            return error.SubcommandRequiresInput;
        }
    }

    var storage = blk: {
        var tmp_arena = std.heap.ArenaAllocator.init(base_allocator);
        defer tmp_arena.deinit();
        const tmp_allocator = tmp_arena.allocator();
        if (mem.eql(u8, ":memory:", db_path)) {
            break :blk try Storage.init(arena_allocator, null);
        }
        var db_location = try getDatabaseLocation(tmp_allocator, db_path);
        break :blk try Storage.init(arena_allocator, db_location);
    };

    var writer = std.io.getStdOut().writer();
    const reader = std.io.getStdIn().reader();
    var cli = command.makeCli(arena_allocator, &storage, cli_options, writer, reader);
    switch (subcmd) {
        .add => try cli.addFeed(args_rest, tags),
        .update => try cli.updateFeeds(),
        .remove => try cli.deleteFeed(args_rest),
        .search => try cli.search(args_rest),
        .clean => try cli.cleanItems(),
        .@"print-feeds" => try cli.printFeeds(),
        .@"print-items" => try cli.printAllItems(),
    }
}

fn getDatabaseLocation(allocator: Allocator, db_option: ?[]const u8) ![:0]const u8 {
    if (db_option) |loc| {
        const db_file = block: {
            if (std.fs.path.isAbsolute(loc)) {
                break :block try std.mem.joinZ(allocator, loc, &.{});
            }
            break :block try std.fs.path.joinZ(allocator, &.{ try std.process.getCwdAlloc(allocator), loc });
        };
        std.fs.accessAbsolute(db_file, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("Provided path '{s}' doesn't exist\n", .{db_file});
                var buf: [1]u8 = undefined;
                while (true) {
                    try stderr.print("Do you want to create database in '{s}' (Y/n)? ", .{db_file});
                    _ = try std.io.getStdIn().read(&buf);
                    const first = buf[0];
                    // Clear characters from stdin
                    while ((try std.io.getStdIn().read(&buf)) != 0) if (buf[0] == '\n') break;
                    const char = std.ascii.toLower(first);
                    if (char == 'y') {
                        break;
                    } else if (char == 'n') {
                        print("Exit app\n", .{});
                        std.os.exit(0);
                    }
                    try stderr.print("Invalid input '{s}' try again.\n", .{db_file});
                }
            },
            else => return err,
        };
        const db_dir = std.fs.path.dirname(db_file).?;
        std.fs.makeDirAbsolute(db_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                log.err("Failed to create directory in '{s}' for database file feedgaze.sqlite", .{db_dir});
                return err;
            },
        };
        return db_file;
    }
    // Get default database location
    const db_file = block: {
        if (try known_folders.getPath(allocator, .local_configuration)) |path| {
            break :block try std.fs.path.joinZ(allocator, &.{ path, "feedgaze", "feedgaze.sqlite" });
        }
        const builtin = @import("builtin");
        if (builtin.target.os.tag == .linux) {
            if (try known_folders.getPath(allocator, .home)) |path| {
                break :block try std.fs.path.joinZ(allocator, &.{ path, ".config", "feedgaze", "feedgaze.sqlite" });
            }
        }
        log.err("Failed to find local configuration or home directory\n", .{});
        return error.MissingConfigAndHomeDir;
    };
    const db_dir = std.fs.path.dirname(db_file).?;
    std.fs.makeDirAbsolute(db_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.err("Failed to create directory in '{s}' for database file feedgaze.sqlite", .{db_dir});
            return err;
        },
    };
    return db_file;
}

const FlagOpt = struct {
    name: []const u8,
    description: []const u8,
    default_value: anytype,
    input_value: ?[]const u8 = null,
};

// TODO: for saving different types in same field check https://github.com/ziglang/zig/issues/10705
// * Tried to save default_value as '?*const anyopaque'. Also default_type fields as 'type'.
//   The problem became default_type which requires comptime. Try to replace default_type
//   'type' with 'TypeInfo'
// * Try to create one functions (getValue) to get flag value. Current setup doesn't allow
//   to figure out return type during comptime. To achive this would have to make Flag type
//   take a comptime type arg. Then probably would have to store different types into
//   different type arrays in FlagSet.

// TODO?: try to add null type that would be parsed as bool or value
// Can cause problems when it is last flag without arguement but there is pos/input value
// Flags can be:
// '--flag-null' - default value will be used
// '--flag-null 2' - 2 will be used
// <no flag> - default value will be used
fn FlagSet(comptime inputs: []FlagOpt) type {
    const FlagValue = union(enum) {
        boolean: bool,
        string: []const u8,
        int: i32,
    };

    const Flag = struct {
        const Self = @This();
        name: []const u8,
        description: []const u8,
        default_value: FlagValue,
        input_value: ?[]const u8 = null,

        fn parseBoolean(value: []const u8) ?bool {
            const true_values = .{ "1", "t", "T", "true", "TRUE", "True" };
            const false_values = .{ "0", "f", "F", "false", "FALSE", "False" };
            inline for (true_values) |t_value| if (mem.eql(u8, value, t_value)) return true;
            inline for (false_values) |f_value| if (mem.eql(u8, value, f_value)) return false;
            return null;
        }

        pub fn getBoolean(self: Self) !bool {
            if (self.default_value != .boolean) {
                return error.NotBooleanValueType;
            }
            if (self.input_value) |input| {
                return parseBoolean(input) orelse self.default_value.boolean;
            }
            return self.default_value.boolean;
        }

        pub fn getString(self: Self) ![]const u8 {
            if (self.default_value != .string) {
                return error.NotStringValueType;
            }
            return self.input_value orelse self.default_value.string;
        }

        pub fn getInt(self: Self) !i32 {
            if (self.input_value) |value| {
                return try std.fmt.parseInt(i32, value, 10);
            }
            return self.default_value.int;
        }
    };

    comptime var precomputed = blk: {
        var flags: [inputs.len]Flag = undefined;
        for (inputs) |flag, i| {
            const type_info = @typeInfo(@TypeOf(flag.default_value));
            const default_value = switch (type_info) {
                .Bool => .{ .boolean = flag.default_value },
                .Pointer => |ptr| blk_ptr: {
                    const child_type = std.meta.Child(ptr.child);
                    if (child_type == u8) {
                        break :blk_ptr .{ .string = flag.default_value };
                    }
                    @compileError("Expecting a u8 slice ([]const u8, []u8), got slice with " ++ @typeName(child_type));
                },
                .Int => .{ .int = @intCast(i64, flag.default_value) },
                else => unreachable,
            };
            flags[i] = Flag{
                .name = flag.name,
                .description = flag.description,
                .default_value = default_value,
                .input_value = flag.input_value,
            };
        }

        break :blk .{ .flags = flags };
    };

    return struct {
        const Self = @This();
        var flags = precomputed.flags;
        // flags: @TypeOf(&precomputed.flags) = &precomputed.flags,
        name: []const u8 = "",
        args: [][:0]const u8 = &[_][:0]u8{},

        pub fn parse(self: *Self, args: [][:0]const u8) !void {
            self.args = args;
            while (try self.parseFlag()) {}
        }

        pub fn getFlags(_: Self) []Flag {
            return &flags;
        }

        fn parseFlag(self: *Self) !bool {
            if (self.args.len == 0) return false;
            const args = self.args;
            const str = args[0];
            // Check if value is valid flag
            if (str.len < 2 or str[0] != '-') return false;
            var minuses: u8 = 1;
            if (str[1] == '-') {
                minuses += 1;
                if (str.len == 2) {
                    self.args = self.args[1..];
                    return error.InvalidFlag;
                }
            }
            var name = str[minuses..];
            // var name: []const u8 = "url";
            if (name.len == 0 or name[0] == '-' or name[0] == '=') {
                return error.BadFlagSyntax;
            }

            // Have a valid flag
            self.args = self.args[1..];

            // Check if flag has value
            var value: ?[]const u8 = null;
            var equal_index: u32 = 1;
            for (name[equal_index..]) |char| {
                if (char == '=') {
                    name = name[0..equal_index :0];
                    value = name[equal_index + 1 ..];
                }
                equal_index += 1;
            }

            var flag = getFlagPtr(name) orelse {
                log.err("Unknown flag provided: -{s}", .{name});
                return error.UnknownFlag;
            };

            if (flag.default_value == .boolean and value == null) {
                value = "true";
            } else {
                if (value == null and self.args.len > 0) {
                    value = self.args[0];
                    self.args = self.args[1..];
                }
                if (value == null) {
                    log.err("Flag -{s} requires a value", .{name});
                    return error.NeedFlagValue;
                }
            }

            flag.input_value = value;
            return true;
        }

        fn getFlagPtr(name: []const u8) ?*Flag {
            for (flags) |*flag| {
                if (mem.eql(u8, name, flag.name)) return flag;
            }
            return null;
        }

        pub fn getFlag(_: *Self, name: []const u8) ?Flag {
            for (flags) |flag| {
                if (mem.eql(u8, name, flag.name)) return flag;
            }
            return null;
        }
    };
}

pub fn newFlag(name: []const u8, default_value: anytype, description: []const u8) FlagOpt {
    return .{
        .name = name,
        .description = description,
        .default_value = default_value,
    };
}

pub fn usage() !void {
    const stderr = std.io.getStdErr();
    const writer = stderr.writer();
    try writer.writeAll("TODO: print usage\n");
}
