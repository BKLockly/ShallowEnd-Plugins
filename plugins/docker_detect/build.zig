const std = @import("std");
const tokota = @import("tokota");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.dependency("tokota", .{
        .target = target,
        .optimize = optimize,
    });

    // Node addon build
    const addon = tokota.Addon.create(b, .{
        .name = "docker",
        .mode = optimize,
        .target = target,
        .root_source_file = b.path("src/root.zig"),
        .output_dir = .{ .custom = "../" },
        .link_libc = true,
    });

    b.getInstallStep().dependOn(&addon.install.step);

    // Test step - separate test file without tokota dependency
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
