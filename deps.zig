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

    pub const zfetch = Pkg{
        .name = "zfetch",
        .path = FileSource{
            .path = ".gyro/zfetch-truemedian-github.com-271cab5d/pkg/src/main.zig",
        },
        .dependencies = &[_]Pkg{
            Pkg{
                .name = "uri",
                .path = FileSource{
                    .path = ".gyro/uri-mattnite-0.0.1-astrolabe.pm/pkg/uri.zig",
                },
            },
            Pkg{
                .name = "hzzp",
                .path = FileSource{
                    .path = ".gyro/hzzp-truemedian-0.1.8-astrolabe.pm/pkg/src/main.zig",
                },
            },
            Pkg{
                .name = "network",
                .path = FileSource{
                    .path = ".gyro/zig-network-MasterQ32-github.com-b9c52822/pkg/network.zig",
                },
            },
            Pkg{
                .name = "iguanaTLS",
                .path = FileSource{
                    .path = ".gyro/iguanaTLS-marler8997-github.com-2b37c575/pkg/src/main.zig",
                },
            },
        },
    };

    pub const clap = Pkg{
        .name = "clap",
        .path = FileSource{
            .path = ".gyro/zig-clap-Hejsil-github.com-0b08e8e3/pkg/clap.zig",
        },
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        artifact.addPackage(pkgs.sqlite);
        artifact.addPackage(pkgs.datetime);
        artifact.addPackage(pkgs.zuri);
        artifact.addPackage(pkgs.zfetch);
        artifact.addPackage(pkgs.clap);
    }
};
