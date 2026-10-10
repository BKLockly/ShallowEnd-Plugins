const std = @import("std");
const tokota = @import("tokota");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tokota_dep = b.dependency("tokota", .{
        .target = target,
        .optimize = optimize,
    });

    // addon 仅对平台矩阵内的 Linux 目标产出；非 Linux host 上无 install step
    if (target.result.os.tag == .linux) {
        const addon = tokota.Addon.create(b, .{
            .name = "load_elf",
            .mode = optimize,
            .target = target,
            .root_source_file = b.path("src/root.zig"),
            .output_dir = .{ .custom = "../" },
            .link_libc = true,
        });
        b.getInstallStep().dependOn(&addon.install.step);
    }

    const test_step = b.step("test", "Run unit tests");

    // 纯逻辑 + 执行链单测（无 tokota；执行链用例仅 Linux 真跑，其余平台跳过）
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    // runner 的 monoNs 走 std.c，必须显式 link libc
    test_mod.link_libc = true;
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // root.zig 编译检查：napi 符号由 Node 运行时提供，独立测试二进制无法链接，
    // generated_bin = null → 只做语义分析，不链接不执行（bof/agentscan 同款处理）
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/root_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.link_libc = true;
    check_mod.addImport("tokota", tokota_dep.module("tokota"));
    const check_tests = b.addTest(.{ .root_module = check_mod });
    check_tests.generated_bin = null;
    test_step.dependOn(&check_tests.step);
}
