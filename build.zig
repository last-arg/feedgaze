const std = @import("std");
const Builder = @import("std").build.Builder;
const LibExeObjStep = @import("std").build.LibExeObjStep;
pub const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("feed_app", "src/main.zig");
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

    const test_file = blk: {
        if (b.args) |args| {
            break :blk args[0];
        }
        break :blk "src/main.zig";
    };

    var test_cmd = b.addTest(test_file);
    test_cmd.setBuildMode(mode);
    stepSetup(test_cmd, target);
    const test_step = b.step("test", "Run file tests");
    test_step.dependOn(&test_cmd.step);

    var test_active_cmd = b.addTest(test_file);
    test_active_cmd.setBuildMode(mode);
    test_active_cmd.setFilter("@active");
    stepSetup(test_active_cmd, target);
    const test_active_step = b.step("test-active", "Run tests with @active");
    test_active_step.dependOn(&test_active_cmd.step);
}

fn stepSetup(step: *LibExeObjStep, target: CrossTarget) void {
    step.linkLibC();
    step.linkSystemLibrary("sqlite3");
    step.addPackage(.{ .name = "sqlite", .path = "lib/zig-sqlite/sqlite.zig" });
    step.addPackage(.{ .name = "datetime", .path = "lib/zig-datetime/datetime.zig" });
    step.addPackage(.{ .name = "xml", .path = "lib/zig-xml/xml.zig" });
    step.addPackage(.{ .name = "hzzp", .path = "lib/hzzp/src/main.zig" });
    step.addPackage(.{ .name = "zig-bearssl", .path = "lib/zig-bearssl/src/lib.zig" });
    @import("lib/zig-bearssl/src/lib.zig").linkBearSSL("./lib/zig-bearssl", step, target);
}
