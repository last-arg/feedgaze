const std = @import("std");
const Builder = @import("std").build.Builder;
const LibExeObjStep = @import("std").build.LibExeObjStep;
pub const CrossTarget = std.zig.CrossTarget;
const pkgs = @import("deps.zig").pkgs;

pub fn build(b: *Builder) void {
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

    stepSetup(exe, target);
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
    test_cmd.setBuildMode(mode);
    stepSetup(test_cmd, target);
    if (b.args) |args| {
        if (args.len >= 2) {
            test_cmd.setFilter(args[1]);
        }
    }
    const test_step = b.step("test", "Run file tests");
    test_step.dependOn(&test_cmd.step);
}

fn stepSetup(step: *LibExeObjStep, _: CrossTarget) void {
    step.linkLibC();
    step.linkSystemLibrary("sqlite3");
    step.addPackagePath("xml", "lib/zig-xml/xml.zig");
    pkgs.addAllTo(step);
}
