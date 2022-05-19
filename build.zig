const std = @import("std");
const Builder = @import("std").build.Builder;
const LibExeObjStep = @import("std").build.LibExeObjStep;
pub const CrossTarget = std.zig.CrossTarget;
const deps = @import("deps.zig");
const pkgs = deps.pkgs;
const mbedtls = deps.build_pkgs.mbedtls;
const libssh2 = deps.build_pkgs.libssh2;
const zlib = deps.build_pkgs.zlib;
const libcurl = deps.build_pkgs.libcurl;

// build.zig example
// https://stackoverflow.com/questions/68609919/using-zig-compiler-as-a-library

pub fn build(b: *Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("feedgaze", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    try stepSetup(b, exe, target, mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_file = if (b.args) |args| args[0] else "src/main.zig";
    var test_cmd = b.addTest(test_file);
    // const test_options = b.addOptions();
    // test_options.addOption(bool, "test-evented-io", true);
    // exe.addOptions("test", test_options);

    test_cmd.setBuildMode(mode);
    try stepSetup(b, test_cmd, target, mode);

    if (b.args) |args| {
        if (args.len >= 2) {
            test_cmd.setFilter(args[1]);
        }
    }

    const test_step = b.step("test", "Run file tests");
    test_step.dependOn(&test_cmd.step);
}

fn stepSetup(b: *Builder, step: *LibExeObjStep, target: CrossTarget, mode: std.builtin.Mode) !void {
    step.linkLibC();
    step.linkSystemLibrary("sqlite3");
    step.addPackagePath("xml", "lib/zig-xml/xml.zig");

    const z = zlib.create(b, target, mode);
    const tls = mbedtls.create(b, target, mode);
    const ssh2 = libssh2.create(b, target, mode);
    tls.link(ssh2.step);

    const curl = try libcurl.create(b, target, mode);
    ssh2.link(curl.step);
    tls.link(curl.step);
    z.link(curl.step, .{});

    z.link(step, .{});
    tls.link(step);
    ssh2.link(step);
    curl.link(step, .{ .import_name = "curl" });

    pkgs.addAllTo(step);
}
