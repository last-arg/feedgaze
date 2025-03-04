const std = @import("std");
const std_build = std.Build;
const Build = std.Build;
const CompileStep = Build.Step.Compile;
pub const CrossTarget = std.zig.CrossTarget;
pub const OptimizeMode = std.builtin.OptimizeMode;

const anon_modules = .{
    .{ .name = "tmp_file", .path = "./tmp/lamplightdev.html" },
    .{ .name = "atom.atom", .path = "./test/atom.atom" },
    .{ .name = "atom.xml", .path = "./test/atom.xml" },
    .{ .name = "rss2.xml", .path = "./test/rss2.xml" },
    .{ .name = "json_feed.json", .path = "./test/json_feed.json" },
    .{ .name = "many-links.html", .path = "./test/many-links.html" },
    .{ .name = "baldurbjarnason.com.html", .path = "./tmp/baldurbjarnason.com.html" },
};

pub fn build(b: *Build) !void {
    // const features = std.Target.Query.parse(.{
    //     // .cpu_features = "native-sse-sse2+soft_float",
    //     .cpu_features = "native-mmx-sse-sse2-sse3-sse4_1-sse4_2",
    // }) catch unreachable;
    const target = b.standardTargetOptions(.{
        // .default_target = features
    });
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = blk: {
        if (b.option(bool, "no-llvm", "Don't use LLVM backend")) |val| {
            break :blk !val;
        }
        break :blk true;
    };

    var source_file: []const u8 = "src/main.zig";
    if (b.args) |args| {
        const value = args[0];
        if (std.mem.endsWith(u8, value, ".zig")) {
            source_file = args[0];
        }
    }

    const opts_exe: Build.ExecutableOptions = .{
        .name = "feedgaze",
        .root_source_file = b.path(source_file),
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    };
    const exe = b.addExecutable(opts_exe);

    b.installArtifact(exe);

    const exe_check = b.addExecutable(opts_exe);
    commonModules(b, exe_check, .{ .target = target, .optimize = optimize });

    // These two lines you might want to copy
    // (make sure to rename 'exe_check')
    const check = b.step("check", "Check if foo compiles");
    check.dependOn(&exe_check.step);

    const run_cmd = b.addRunArtifact(exe);

    const tmp_file = anon_modules[0];
    exe.root_module.addAnonymousImport(tmp_file.name, .{
        .root_source_file = b.path(tmp_file.path),
    });

    commonModules(b, exe, .{ .target = target, .optimize = optimize });

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

    // Creates a step for unit testing.
    var test_source: []const u8 = source_file;
    var cmds: []const ?[]const u8 = &.{};
    var filter: ?[]const u8 = null;
    if (b.args) |args| {
        test_source = args[0];
        if (args.len >= 2) {
            filter = args[1];
            cmds = @ptrCast(args[2..]);
        }
    }
    var test_cmd = b.addTest(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .filter = filter,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    inline for (anon_modules) |file| {
        test_cmd.root_module.addAnonymousImport(file.name, .{
            .root_source_file = b.path(file.path),
        });
    }

    commonModules(b, test_cmd, .{ .target = target, .optimize = optimize });

    const run_unit_tests = b.addRunArtifact(test_cmd);
    const test_step = b.step("test", "Run file tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn commonModules(b: *Build, step: *CompileStep, dep_args: anytype) void {
    step.linkLibC();
    const sqlite_dep = b.dependency("sqlite", dep_args);
    step.linkSystemLibrary("sqlite3");
    // step.installLibraryHeaders(sqlite_dep.artifact("sqlite"));
    step.root_module.addImport("sqlite", sqlite_dep.module("sqlite"));

    const args = b.dependency("args", dep_args);
    step.root_module.addImport("zig-args", args.module("args"));

    const datetime = b.dependency("zig-datetime", dep_args);
    step.root_module.addImport("zig-datetime", datetime.module("zig-datetime"));

    const known_folders = b.dependency("known-folders", .{});
    step.root_module.addImport("known-folders", known_folders.module("known-folders"));

    const xml = b.dependency("xml", dep_args);
    step.root_module.addImport("xml", xml.module("xml"));

    const curl = b.dependency("curl", .{.link_vendor = false});
    step.root_module.addImport("curl", curl.module("curl"));
    step.linkSystemLibrary("curl");

    const httpz = b.dependency("httpz", .{});
    step.root_module.addImport("httpz", httpz.module("httpz"));

    const superhtml = b.dependency("superhtml", .{});
    step.root_module.addImport("superhtml", superhtml.module("superhtml"));
}
