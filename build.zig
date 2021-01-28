const std = @import("std");
const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("feed_inbox", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");
    exe.addPackage(.{ .name = "sqlite", .path = "lib/zig-sqlite/sqlite.zig" });
    exe.addPackage(.{ .name = "datetime", .path = "lib/zig-datetime/datetime.zig" });
    exe.addPackage(.{ .name = "xml", .path = "lib/zig-xml/xml.zig" });
    exe.addPackage(.{ .name = "hzzp", .path = "lib/hzzp/src/main.zig" });
    exe.addPackage(.{ .name = "zig-bearssl", .path = "lib/zig-bearssl/bearssl.zig" });
    @import("lib/zig-bearssl/bearssl.zig").linkBearSSL("./lib/zig-bearssl", exe, target);
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

    var file_test = b.addTest(test_file);
    file_test.setBuildMode(mode);
    if (std.mem.eql(u8, "src/main.zig", test_file)) {
        file_test.setFilter("active");
    }

    file_test.linkLibC();
    file_test.linkSystemLibrary("sqlite3");
    file_test.addPackage(.{ .name = "sqlite", .path = "lib/zig-sqlite/sqlite.zig" });
    file_test.addPackage(.{ .name = "datetime", .path = "lib/zig-datetime/datetime.zig" });
    file_test.addPackage(.{ .name = "xml", .path = "lib/zig-xml/xml.zig" });
    file_test.addPackage(.{ .name = "hzzp", .path = "lib/hzzp/src/main.zig" });
    file_test.addPackage(.{ .name = "zig-bearssl", .path = "lib/zig-bearssl/bearssl.zig" });
    @import("lib/zig-bearssl/bearssl.zig").linkBearSSL("./lib/zig-bearssl", file_test, target);

    const test_step = b.step("test", "Run file tests");
    test_step.dependOn(&file_test.step);
}
