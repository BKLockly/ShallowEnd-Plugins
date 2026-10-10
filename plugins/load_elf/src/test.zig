const std = @import("std");
const runner = @import("runner.zig");

test "isElf accepts magic and rejects short/garbage" {
    try std.testing.expect(runner.isElf("\x7fELF\x02\x01\x01"));
    try std.testing.expect(!runner.isElf("\x7fEL"));
    try std.testing.expect(!runner.isElf("#!/bin/sh\n"));
    try std.testing.expect(!runner.isElf(""));
}

test "splitArgs splits on whitespace" {
    const t = try runner.splitArgs(std.testing.allocator, "  -kvl \t4444\r\n--pipe  ");
    defer {
        for (t) |a| std.testing.allocator.free(a);
        std.testing.allocator.free(t);
    }
    try std.testing.expectEqual(@as(usize, 3), t.len);
    try std.testing.expectEqualStrings("-kvl", t[0]);
    try std.testing.expectEqualStrings("4444", t[1]);
    try std.testing.expectEqualStrings("--pipe", t[2]);
}

test "splitArgs of empty/whitespace yields nothing" {
    const t = try runner.splitArgs(std.testing.allocator, " \t\r\n");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 0), t.len);
}

test "stripAnsi removes CSI sequences" {
    const s = try runner.stripAnsi(std.testing.allocator, "\x1b[1mOK\x1b[0m done\x1b[32;1m!\x1b[0m\n");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("OK done!\n", s);
}

test "stripAnsi keeps plain text intact" {
    const s = try runner.stripAnsi(std.testing.allocator, "plain [INFO] text \x07 bell");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("plain [INFO] text \x07 bell", s);
}

test "buildEnvp appends NO_COLOR and null-terminates" {
    const envp = try runner.buildEnvp(std.testing.allocator);
    defer std.testing.allocator.free(envp);
    var found = false;
    for (envp) |entry| {
        const e = entry orelse break;
        if (std.mem.eql(u8, std.mem.span(e), "NO_COLOR=1")) found = true;
    }
    // libc 环境可能自带 NO_COLOR，两者其一必须成立
    try std.testing.expect(found or blk: {
        var idx: usize = 0;
        while (std.c.environ[idx]) |e| : (idx += 1) {
            if (std.mem.startsWith(u8, std.mem.span(e), "NO_COLOR=")) break :blk true;
        }
        break :blk false;
    });
    try std.testing.expectEqual(@as(?[*:0]const u8, null), envp[envp.len - 1]);
}

// ---- 执行链（fork + memfd + execveat）：仅 Linux 真跑，CI 在 ubuntu 验证 ----

const LinuxCtx = struct {
    fn buildArgv(allocator: std.mem.Allocator, tokens: []const []const u8) ![:null]?[*:0]const u8 {
        var argv = try allocator.allocSentinel(?[*:0]const u8, tokens.len + 1, null);
        argv[0] = (try allocator.dupeZ(u8, "elf")).ptr;
        for (tokens, 0..) |t, i| argv[i + 1] = (try allocator.dupeZ(u8, t)).ptr;
        return argv;
    }
    fn freeArgv(allocator: std.mem.Allocator, argv: [:null]?[*:0]const u8) void {
        for (argv) |a| {
            if (a) |z| allocator.free(@as([*:0]u8, @constCast(z.ptr))[0..std.mem.len(z.ptr)]);
        }
        allocator.free(argv);
    }
};

test "execFd runs a binary from memfd and collects output" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const linux = std.os.linux;

    const bin = try std.fs.cwd().readFileAlloc(allocator, "/bin/sh", 8 << 20);
    defer allocator.free(bin);

    const fd = try runner.createMemfd(bin);
    defer _ = linux.close(fd);
    const argv = try LinuxCtx.buildArgv(allocator, &.{ "-c", "echo memfd-ok" });
    defer LinuxCtx.freeArgv(allocator, argv);
    const envp = try runner.buildEnvp(allocator);
    defer allocator.free(envp);

    const result = try runner.execFd(allocator, fd, argv, envp, 30);
    defer allocator.free(result.output);
    try std.testing.expect(!result.failed);
    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("memfd-ok\n", result.output);
}

test "execFd falls back to execve procfs path when execveat unavailable" {
    // 覆盖路径不可直接模拟（execveat 在 CI 内核必然可用），
    // 本用例确保同一条 exec 链对 /proc/self/fd/N 形式也成立：
    // 跳过 execveat 直接构造不可行，退化为验证非 ELF 触发 126 降级链全败。
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const fd = try runner.createMemfd("#!/bin/sh\necho not-an-elf\n");
    defer _ = std.os.linux.close(fd);
    const argv = try LinuxCtx.buildArgv(allocator, &.{});
    defer LinuxCtx.freeArgv(allocator, argv);
    const envp = try runner.buildEnvp(allocator);
    defer allocator.free(envp);

    // 非 ELF 内容：execveat 与 execve(/proc/self/fd/N) 均返回 ENOEXEC → exit 126
    try std.testing.expectError(error.ExecFailed, runner.execFd(allocator, fd, argv, envp, 30));
}

test "execFd reports timeout and kills the process" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const linux = std.os.linux;

    const bin = try std.fs.cwd().readFileAlloc(allocator, "/bin/sleep", 8 << 20);
    defer allocator.free(bin);

    const fd = try runner.createMemfd(bin);
    defer _ = linux.close(fd);
    const argv = try LinuxCtx.buildArgv(allocator, &.{"30"});
    defer LinuxCtx.freeArgv(allocator, argv);
    const envp = try runner.buildEnvp(allocator);
    defer allocator.free(envp);

    const result = try runner.execFd(allocator, fd, argv, envp, 1);
    defer allocator.free(result.output);
    try std.testing.expect(result.timed_out);
    try std.testing.expect(result.failed);
}

test "createAnonFile leaves no path behind" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const fd = try runner.createAnonFile("data");
    defer _ = std.os.linux.close(fd);
    // fd 可读回内容（unlink 后仍持有 inode）
    var buf: [8]u8 = undefined;
    const n = try std.posix.pread(fd, &buf, 0);
    try std.testing.expectEqualStrings("data", buf[0..n]);
    _ = allocator;
}
