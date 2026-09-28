const std = @import("std");
const tokota = @import("tokota");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.dependency("tokota", .{
        .target = target,
        .optimize = optimize,
    });

    const addon = tokota.Addon.create(b, .{
        .name = "bof",
        .mode = optimize,
        .target = target,
        .root_source_file = b.path("src/root.zig"),
        .output_dir = .{ .custom = "../" },
        .link_libc = true,
    });
    addon.root_module.linkSystemLibrary("pthread", .{});

    const lib_name = b.fmt("libbof_launcher_lin_{s}.a", .{switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "aarch64",
        else => @panic("unsupported arch"),
    }});
    const lib_subdir = switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "linux-x64",
            .aarch64 => "linux-arm64",
            else => @panic("unsupported arch"),
        },
        else => @panic("unsupported OS"),
    };
    addon.root_module.addObjectFile(b.path(b.fmt("lib/{s}/{s}", .{ lib_subdir, lib_name })));

    addon.root_module.addIncludePath(b.path("lib/include"));

    b.getInstallStep().dependOn(&addon.install.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
