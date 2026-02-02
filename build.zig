const std = @import("std");
const std_build = std.Build;
const Build = std.Build;
const CompileStep = Build.Step.Compile;
pub const CrossTarget = std.zig.CrossTarget;
pub const OptimizeMode = std.builtin.OptimizeMode;

const anon_modules = .{
    // .{ .name = "tmp_file", .path = "./tmp/feed_urls.txt" },
    .{ .name = "tmp_file", .path = "./tmp/@freya.rss" },
    // .{ .name = "tmp_file", .path = "./test/atom.atom" },
    .{ .name = "atom.atom", .path = "./test/atom.atom" },
    .{ .name = "atom.xml", .path = "./test/atom.xml" },
    .{ .name = "rss2.xml", .path = "./test/rss2.xml" },
    .{ .name = "json_feed.json", .path = "./test/json_feed.json" },
    .{ .name = "many-links.html", .path = "./test/many-links.html" },
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var source_file: []const u8 = "src/main.zig";
    if (b.args) |args| {
        const value = args[0];
        if (std.mem.endsWith(u8, value, ".zig")) {
            source_file = args[0];
        }
    }

    const opts_exe: Build.ExecutableOptions = .{
        .name = "feedgaze",
        .root_module = b.createModule(.{ // this line was added
            .root_source_file = b.path(source_file),
            .target = target,
            .optimize = optimize,
        }),
        // TODO: currently this will fail in debug build which uses zig's own
        // backend. Just fails no specific error message.
        // Have to enable 'use_llvm' to compile in debug mode
        .use_llvm = true,
        // .use_lld = true,
    };

    if (@import("builtin").mode != .Debug) {
        const esbuild = b.findProgram(&.{"esbuild"}, &.{}) catch
            @panic("Could not find command 'esbuild'");
        const command_minify = b.addSystemCommand(&.{
            esbuild,
            "--allow-overwrite",
            "--log-level=error",
            "--bundle",
            "--minify",
            "src/server/main.css",
            "src/server/main.js",
            "src/server/relative-time.js",
            "--outdir=src/server/dist"
        });
        b.getInstallStep().dependOn(&command_minify.step);

        if (b.findProgram(&.{"purgecss"}, &.{})) |purgecss| {
            const command_purgecss = b.addSystemCommand(&.{
                purgecss,
                "--config",
                "./purgecss-cli.config.js"
            });
            command_purgecss.step.dependOn(&command_minify.step);
            b.getInstallStep().dependOn(&command_purgecss.step);
        } else |_| {
            std.log.err("Missing command 'purgecss'. Can't remove unused CSS", .{});
        }
        
    }
    
    const exe = b.addExecutable(opts_exe);
    exe.is_linking_libc = true;

    b.installArtifact(exe);

    const exe_check = b.addExecutable(opts_exe);
    commonModules(b, exe_check, .{ .target = target, .optimize = optimize });

    const check = b.step("check", "Check if app compiles");
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
        .root_module = b.createModule(.{ // this line was added
            .root_source_file = b.path(test_source),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (filter) |f| &.{f} else &.{},
        // .use_llvm = true,
        // .use_lld = false,
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


    const opts_ico: Build.ExecutableOptions = .{
        .name = "img_ico",
        .root_module = b.createModule(.{ // this line was added
            .root_source_file = b.path("src/img_ico.zig"),
            .target = target,
            .optimize = optimize,
        }),
    };

    const exe_ico = b.addExecutable(opts_ico);
    b.installArtifact(exe);
    const ico_cmd = b.addRunArtifact(exe_ico);

    const ico_step = b.step("ico", "run img_ico");
    ico_step.dependOn(&ico_cmd.step);
    
    
}

fn commonModules(b: *Build, step: *CompileStep, dep_args: anytype) void {
    const root = step.root_module;

    const sqlite_dep = b.dependency("sqlite", dep_args);
    root.linkSystemLibrary("sqlite3", .{});
    root.addImport("sqlite", sqlite_dep.module("sqlite"));

    const args = b.dependency("args", dep_args);
    step.root_module.addImport("zig-args", args.module("args"));

    const datetime = b.dependency("zig-datetime", dep_args);
    step.root_module.addImport("zig-datetime", datetime.module("datetime"));

    const known_folders = b.dependency("known-folders", .{});
    step.root_module.addImport("known-folders", known_folders.module("known-folders"));

    const httpz = b.dependency("httpz", .{});
    step.root_module.addImport("httpz", httpz.module("httpz"));

    const superhtml = b.dependency("superhtml", .{});
    step.root_module.addImport("superhtml", superhtml.module("superhtml"));

    const zts = b.dependency("zts", .{});
    step.root_module.addImport("zts", zts.module("zts"));
}
