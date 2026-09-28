const std = @import("std");
const tokota = @import("tokota");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tokota_dep = b.dependency("tokota", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_name = b.fmt("libbof_launcher_lin_{s}.a", .{switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "aarch64",
        else => @panic("unsupported arch"),
    }});
    const lib_subdir = switch (target.result.cpu.arch) {
        .x86_64 => "linux-x64",
        .aarch64 => "linux-arm64",
        else => @panic("unsupported arch"),
    };

    // addon/静态库只对 Linux 目标有意义；非 Linux host 跑 `zig build test` 时跳过
    if (target.result.os.tag == .linux) {
        const addon = tokota.Addon.create(b, .{
            .name = "bof",
            .mode = optimize,
            .target = target,
            .root_source_file = b.path("src/root.zig"),
            .output_dir = .{ .custom = "../" },
            .link_libc = true,
        });
        addon.root_module.linkSystemLibrary("pthread", .{});

        addon.root_module.addObjectFile(b.path(b.fmt("lib/{s}/{s}", .{ lib_subdir, lib_name })));

        addon.root_module.addIncludePath(b.path("lib/include"));

        b.getInstallStep().dependOn(&addon.install.step);
    }

    const test_step = b.step("test", "Run unit tests");

    if (target.result.os.tag == .linux) {
        // bof 测试需要静态链接 bof_launcher（编译 root.zig 即测试），
        // 仅 Linux 目标可链接；非 Linux host 上 test 步骤为空操作（CI 在 ubuntu 上真跑）。
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("tokota", tokota_dep.module("tokota"));
        test_mod.addIncludePath(b.path("lib/include"));
        test_mod.link_libc = true;
        test_mod.addObjectFile(b.path(b.fmt("lib/{s}/{s}", .{ lib_subdir, lib_name })));

        const unit_tests = b.addTest(.{
            .root_module = test_mod,
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
}
