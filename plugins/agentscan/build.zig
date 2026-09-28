const std = @import("std");
const tokota = @import("tokota");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tokota_dep = b.dependency("tokota", .{
        .target = target,
        .optimize = optimize,
    });

    // 内嵌的 Go 二进制固定 GOOS=linux，GOARCH 跟随 zig 目标架构；
    // 其他架构不在平台矩阵内，直接不出任何 step。
    const goarch = switch (target.result.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => return,
    };

    // 1) 编译 vendored 上游（纯 Go，无 cgo，静态链接）
    const go_build = b.addSystemCommand(&.{ "go", "build", "-trimpath", "-ldflags=-s -w", "-o" });
    const go_bin = go_build.addOutputFileArg("agentscan");
    go_build.addArg(".");
    go_build.setCwd(b.path("agentscan"));
    go_build.setEnvironmentVariable("CGO_ENABLED", "0");
    go_build.setEnvironmentVariable("GOOS", "linux");
    go_build.setEnvironmentVariable("GOARCH", goarch);

    // 2) gzip 压缩（9MB → ~3.7MB，降低 .node 体积）
    const gzip = b.addSystemCommand(&.{ "sh", "-c", "gzip -9 -n -c \"$1\" > \"$2\"", "agentscan-gzip" });
    gzip.addFileArg(go_bin);
    const go_gz = gzip.addOutputFileArg("payload.gz");

    // 3) 生成 payload 模块：@embedFile 内嵌 gzip 字节
    const wf = b.addWriteFiles();
    const payload_zig = wf.add("payload.zig", "pub const bin = @embedFile(\"payload.gz\");\n");
    _ = wf.addCopyFile(go_gz, "payload.gz");
    const payload_mod = b.createModule(.{
        .root_source_file = payload_zig,
        .target = target,
        .optimize = optimize,
    });

    const addon = tokota.Addon.create(b, .{
        .name = "agentscan",
        .mode = optimize,
        .target = target,
        .root_source_file = b.path("src/root.zig"),
        .output_dir = .{ .custom = "../" },
        .link_libc = true,
    });
    addon.root_module.addImport("payload", payload_mod);
    b.getInstallStep().dependOn(&addon.install.step);

    const test_step = b.step("test", "Run unit tests");

    // 纯逻辑单测（无 tokota，真跑）
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // root.zig 编译检查：napi 符号由 Node 运行时提供，独立测试二进制无法链接，
    // generated_bin = null → 只做语义分析，不链接不执行（bof 同款处理）
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/root_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.addImport("tokota", tokota_dep.module("tokota"));
    check_mod.addImport("payload", payload_mod);
    const check_tests = b.addTest(.{ .root_module = check_mod });
    check_tests.generated_bin = null;
    test_step.dependOn(&check_tests.step);
}
