const std = @import("std");
const std_build = @import("std").build;
const Builder = std_build.Builder;
const CompileStep = std_build.CompileStep;
const LibExeObjStep = std_build.LibExeObjStep;
pub const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "feedgaze",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a RunStep in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    commonModules(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var test_file: []const u8 = "src/main.zig";
    var filter: ?[]const u8 = null;
    var arr = try std.BoundedArray(?[]const u8, 10).init(1);
    arr.set(0, null);
    if (b.args) |args| {
        test_file = args[0];
        if (args.len >= 2) {
            filter = args[1];
            try arr.appendSlice(@ptrCast(args[2..]));
        }
    }
    // Creates a step for unit testing.
    var test_cmd = b.addTest(.{
        .root_source_file = .{ .path = test_file },
        .target = target,
        .optimize = optimize,
    });
    test_cmd.filter = filter;
    test_cmd.setExecCmd(arr.constSlice());

    test_cmd.addAnonymousModule("atom.atom", .{
        .source_file = .{ .path = "./test/atom.atom" },
    });

    test_cmd.addAnonymousModule("rss2.xml", .{
        .source_file = .{ .path = "./test/rss2.xml" },
    });

    commonModules(test_cmd);
    test_cmd.addAnonymousModule("rss2.xml", .{
        .source_file = .{ .path = "./test/rss2.xml" },
    });

    const run_unit_tests = b.addRunArtifact(test_cmd);
    const test_step = b.step("test", "Run file tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn commonModules(step: *CompileStep) void {
    step.linkLibC();
    step.linkSystemLibrary("sqlite3");
    step.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "./lib/zig-sqlite/sqlite.zig" },
    });
    step.addAnonymousModule("zig-xml", .{
        .source_file = .{ .path = "./lib/zig-xml/xml.zig" },
    });
    step.addAnonymousModule("zig-args", .{
        .source_file = .{ .path = "./lib/zig-args/args.zig" },
    });
    step.addAnonymousModule("zig-datetime", .{
        .source_file = .{ .path = "./lib/zig-datetime/src/main.zig" },
    });
}
