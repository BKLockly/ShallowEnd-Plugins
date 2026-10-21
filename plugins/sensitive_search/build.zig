const std = @import("std");
const tokota = @import("tokota");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tokota_dep = b.dependency("tokota", .{
        .target = target,
        .optimize = optimize,
    });

    const addon = tokota.Addon.create(b, .{
        .name = "sensitive_search",
        .mode = optimize,
        .target = target,
        .root_source_file = b.path("src/root.zig"),
        .output_dir = .{ .custom = "../" },
        .link_libc = true,
    });

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

    if (target.result.os.tag == .linux) {
        // root.zig 编译检查（含 scanner.zig 调用链；scanner Linux-only，
        // 故仅在 Linux 目标上启用，bof 同款门控）：generated_bin = null
        // → 只做语义分析，不链接不执行
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
}
