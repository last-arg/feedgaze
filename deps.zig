const std = @import("std");
const Pkg = std.build.Pkg;
const FileSource = std.build.FileSource;

pub const pkgs = struct {
    pub const sqlite = Pkg{
        .name = "sqlite",
        .path = FileSource{
            .path = ".gyro/zig-sqlite-vrischmann-github.com-b7745314/pkg/sqlite.zig",
        },
    };

    pub const datetime = Pkg{
        .name = "datetime",
        .path = FileSource{
            .path = ".gyro/zig-datetime-frmdstryr-github.com-901a7e25/pkg/src/main.zig",
        },
    };

    pub const zuri = Pkg{
        .name = "zuri",
        .path = FileSource{
            .path = ".gyro/zuri-Vexu-github.com-d5cce7e5/pkg/src/zuri.zig",
        },
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        artifact.addPackage(pkgs.sqlite);
        artifact.addPackage(pkgs.datetime);
        artifact.addPackage(pkgs.zuri);
    }
};
