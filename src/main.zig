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

// TODO: need to replace disk db, doesn't work with new code anymore
// TODO: auto add some data for fast cli testing

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const base_allocator = gpa.allocator();
    // const base_allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const help_flag = newFlag("help", false, "Display this help and exit.");
    const db_flag = newFlag("db", "~/.config/feedgaze/feedgaze.sqlite", "Point to sqlite database location.");
    const url_flag = newFlag("url", true, "Apply action only to url feeds.");
    const local_flag = newFlag("local", true, "Apply action only to local feeds.");
    // TODO: implement '--default' flag. Can have none to multiple values. Do comma separate values?   clap.parseParam("-f, --force    Force update all feeds. Subcommand: update") catch unreachable,

    comptime var add_flags = [_]FlagOpt{ help_flag, url_flag, local_flag, db_flag };
    const AddCmd = FlagSet(&add_flags);
    comptime var print_feeds_flags = [_]FlagOpt{ help_flag, url_flag, local_flag, db_flag };
    const PrintFeedsCmd = FlagSet(&print_feeds_flags);

    comptime var add_cmd = AddCmd{ .name = "add" };
    _ = add_cmd;
    comptime var print_feeds_cmd = PrintFeedsCmd{ .name = "print-feeds" };
    _ = print_feeds_cmd;

    var args = try process.argsAlloc(std.testing.allocator);
    defer process.argsFree(std.testing.allocator, args);

    // TODO: need to check if help flag vas entered
    if (args.len == 1) {
        log.err("No subcommand entered.", .{});
        return error.MissingSubCommand;
    }

    const Subcommand = enum { add, update, delete, search, clean, @"print-feeds", @"print-items" };
    const subcmd_str = args[1];
    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_str) orelse {
        log.err("Unknown subcommand '{s}'.", .{subcmd_str});
        return error.UnknownSubCommand;
    };

    const cmds = struct {
        add: AddCmd = add_cmd,
        update: AddCmd = add_cmd,
        delete: AddCmd = add_cmd,
        search: AddCmd = add_cmd,
        clean: AddCmd = add_cmd,
        @"print-feeds": PrintFeedsCmd = print_feeds_cmd,
        @"print-items": PrintFeedsCmd = print_feeds_cmd,
    }{};

    var args_rest: [][:0]const u8 = undefined;
    var db_path: []const u8 = undefined;
    var cli_options = command.CliOptions{
        .force = false,
        .url = true,
        .local = true,
    };

    // Parse args
    inline for (comptime std.meta.fieldNames(Subcommand)) |name| {
        if (subcmd == std.meta.stringToEnum(Subcommand, name)) {
            var cmd = @field(cmds, name);
            try cmd.parse(args[2..]);
            args_rest = cmd.args;
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

            // Don't use break, continue, return inside inline loops
            // https://github.com/ziglang/zig/issues/2727
            // https://github.com/ziglang/zig/issues/9524
        }
    }

    const subcom_input_required = [_]Subcommand{ .add, .delete, .search };
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
        .add => try cli.addFeed(args_rest),
        .update => try cli.updateFeeds(),
        // TODO: multiple values will be OR-ed
        .delete => try cli.deleteFeed(args_rest[0]),
        // TODO: multiple values will be OR-ed
        .search => try cli.search(args_rest[0]),
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

fn FlagSet(comptime inputs: []FlagOpt) type {
    const FlagValue = union(enum) {
        boolean: bool,
        string: []const u8,
    };

    const Flag = struct {
        const Self = @This();
        name: []const u8,
        description: []const u8,
        default_value: FlagValue,
        input_value: ?[]const u8 = null,

        pub fn getBoolean(self: Self) !bool {
            if (self.default_value != .boolean) {
                return error.NotBooleanValueType;
            }
            if (self.input_value) |input| {
                const valid_values = .{ "1", "0", "t", "f", "T", "F", "true", "false", "TRUE", "FALSE", "True", "False" };
                // TODO?: toLower(input)?
                inline for (valid_values) |value| {
                    if (mem.eql(u8, value, input)) return true;
                }
                return false;
            }
            return self.default_value.boolean;
        }

        pub fn getString(self: Self) ![]const u8 {
            if (self.default_value != .string) {
                return error.NotStringValueType;
            }
            return self.input_value orelse self.default_value.string;
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
            // TODO: not good condition, some subcommands need end pos args
            while (self.args.len > 0) {
                self.parseFlag() catch |err| switch (err) {
                    error.NoMoreFlags => break,
                    else => return err,
                };
            }
        }

        pub fn getFlags(_: Self) []Flag {
            return &flags;
        }

        fn parseFlag(self: *Self) !void {
            if (self.args.len == 0) return;
            const args = self.args;
            const str = args[0];
            // Check if value is valid flag
            if (str.len < 2 or str[0] != '-') return error.NoMoreFlags;
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
