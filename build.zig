const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zosc = b.addModule("zosc", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    const zoscbin = b.addExecutable(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        }),
        .name = "zoscsend",
    });
    zoscbin.root_module.addImport("zosc", zosc);
    if (target.result.os.tag != .windows and target.result.os.tag != .wasi) {
        const zoscsend = b.addInstallArtifact(zoscbin, .{ .dest_sub_path = "zoscsend" });
        const zoscdump = b.addInstallArtifact(zoscbin, .{ .dest_sub_path = "zoscdump" });
        const install = b.getInstallStep();
        install.dependOn(&zoscsend.step);
        install.dependOn(&zoscdump.step);
    }

    const comp_check = b.addTest(.{
        .root_module = zosc,
    });
    const check = b.step("check", "check for compile errors");
    check.dependOn(&comp_check.step);

    const tests = b.addTest(.{
        .root_module = zosc,
    });
    const tests_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "run tests");
    test_step.dependOn(&tests_run.step);

    const header = b.addInstallHeaderFile(b.path("include/zosc.h"), "zosc.h");

    // Static C lib
    if (target.result.os.tag != .wasi) {
        const static_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "zosc",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/c_api.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        static_lib.root_module.addImport("zosc", zosc);
        b.installArtifact(static_lib);
        b.default_step.dependOn(&static_lib.step);
        b.getInstallStep().dependOn(&header.step);
    }

    if (target.query.isNative()) {
        const dynamic_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "zosc",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/c_api.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        dynamic_lib.root_module.addImport("zosc", zosc);
        b.installArtifact(dynamic_lib);
        b.default_step.dependOn(&dynamic_lib.step);
        b.getInstallStep().dependOn(&header.step);
    }

    // C headers
    const c_header = b.addInstallFileWithDir(
        b.path("include/zosc.h"),
        .header,
        "zosc.h",
    );
    b.getInstallStep().dependOn(&c_header.step);

    // pkg-config
    {
        const file = try b.cache_root.join(b.allocator, &.{"zosc.pc"});
        const pkgconfig_file = try std.fs.cwd().createFile(file, .{});
        defer pkgconfig_file.close();

        var buf: [2048]u8 = undefined;
        var writer = pkgconfig_file.writer(&buf);
        try writer.interface.print(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: zosc
            \\URL: https://github.com/robbielyman/zosc
            \\Description: Zig-powered implementation of OSC messaging and servers
            \\Version: 0.1.0
            \\Cflags: -I${{includedir}}
            \\Libs: -L${{libdir}} -lzosc
        , .{b.install_prefix});
        try writer.end();

        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            .{ .cwd_relative = file },
            .prefix,
            "share/pkgconfig/zosc.pc",
        ).step);
    }
}
