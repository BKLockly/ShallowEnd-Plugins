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

test "resolveArgv0 precedence: explicit > filename basename > elf" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ @as(?[]const u8, "busybox"), @as(?[]const u8, "/tmp/up/busybox-arm64"), "busybox" }, // 显式参数最高优先
        .{ null, "/tmp/up/sleep", "sleep" }, // 缺省取文件名 basename
        .{ null, "wget", "wget" }, // 纯文件名原样
        .{ "", null, "elf" }, // 双缺省兜底
        .{ null, null, "elf" },
        .{ null, "/a/b/", "elf" }, // basename 为空（目录斜杠结尾）回退兜底
        .{ "  ", "/a/b/sh", "sh" }, // 空白显式值视为未提供，落到文件名
    };
    inline for (cases) |c| {
        const got = try runner.resolveArgv0(allocator, c[0], c[1]);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c[2], got);
    }
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
    fn buildArgv(allocator: std.mem.Allocator, argv0: []const u8, tokens: []const []const u8) ![:null]?[*:0]const u8 {
        var argv = try allocator.allocSentinel(?[*:0]const u8, tokens.len + 1, null);
        argv[0] = (try allocator.dupeZ(u8, argv0)).ptr;
        for (tokens, 0..) |t, i| argv[i + 1] = (try allocator.dupeZ(u8, t)).ptr;
        return argv;
    }
    fn freeArgv(allocator: std.mem.Allocator, argv: [:null]?[*:0]const u8) void {
        for (argv) |a| {
            // span 恢复 [:0]u8 sentinel 形态，free 才能按 len+1 释放（dupeZ 分配量）
            if (a) |z| allocator.free(std.mem.span(@constCast(z)));
        }
        allocator.free(argv);
    }
};

// 0.16 起 std.fs.cwd() 移除，文件读取走 std.Io.Dir + Io 实例
var test_threaded: std.Io.Threaded = .init_single_threaded;

test "execFd runs a binary from memfd and collects output" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const linux = std.os.linux;

    const bin = try std.Io.Dir.cwd().readFileAlloc(test_threaded.io(), "/bin/sh", allocator, .limited(8 << 20));
    defer allocator.free(bin);

    const fd = try runner.createMemfd(bin);
    defer _ = linux.close(fd);
    const argv = try LinuxCtx.buildArgv(allocator, "sh", &.{ "-c", "echo memfd-ok" });
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
    // 本用例确保 exec 降级链全败时的 126 语义成立：喂无 shebang 的纯文本
    // （带 #! 会被内核 binfmt_script 拦截而非 ENOEXEC），execveat 与
    // execve(/proc/self/fd/N) 均返回 ENOEXEC → exit 126。
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const fd = try runner.createMemfd("not an elf at all\n");
    defer _ = std.os.linux.close(fd);
    const argv = try LinuxCtx.buildArgv(allocator, "sh", &.{});
    defer LinuxCtx.freeArgv(allocator, argv);
    const envp = try runner.buildEnvp(allocator);
    defer allocator.free(envp);

    // 126 分支返回前不持有 output，但正常返回路径的 result 须先释放再断言
    const outcome = runner.execFd(allocator, fd, argv, envp, 30);
    if (outcome) |r| allocator.free(r.output) else |_| {}
    try std.testing.expectError(error.ExecFailed, outcome);
}

test "execFd reports timeout and kills the process" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const linux = std.os.linux;

    const bin = try std.Io.Dir.cwd().readFileAlloc(test_threaded.io(), "/bin/sleep", allocator, .limited(8 << 20));
    defer allocator.free(bin);

    const fd = try runner.createMemfd(bin);
    defer _ = linux.close(fd);
    const argv = try LinuxCtx.buildArgv(allocator, "sleep", &.{"30"});
    defer LinuxCtx.freeArgv(allocator, argv);
    const envp = try runner.buildEnvp(allocator);
    defer allocator.free(envp);

    const result = try runner.execFd(allocator, fd, argv, envp, 1);
    defer allocator.free(result.output);
    try std.testing.expect(result.timed_out);
    try std.testing.expect(result.failed);
}

// 回归：孙进程持有管道写端时拖干循环不得无限阻塞。直接子进程 exec 的 sleep
// 被超时 SIGKILL 后，后台孙进程仍握着写端，EOF 不来——修复前 read 无限阻塞
// 到孙进程退出（sleep 15），修复后拖干最多再等 2s 必须返回。
test "execFd drain gives up when a grandchild holds the pipe write end" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const linux = std.os.linux;

    const bin = try std.Io.Dir.cwd().readFileAlloc(test_threaded.io(), "/bin/sh", allocator, .limited(8 << 20));
    defer allocator.free(bin);

    const fd = try runner.createMemfd(bin);
    defer _ = linux.close(fd);
    const argv = try LinuxCtx.buildArgv(allocator, "sh", &.{ "-c", "sleep 15 & exec sleep 15" });
    defer LinuxCtx.freeArgv(allocator, argv);
    const envp = try runner.buildEnvp(allocator);
    defer allocator.free(envp);

    const clk: std.c.clockid_t = if (comptime runner.is_linux)
        @as(std.os.linux.clockid_t, .MONOTONIC)
    else
        1;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    const start_ns = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;

    const result = try runner.execFd(allocator, fd, argv, envp, 1);
    defer allocator.free(result.output);

    _ = std.c.clock_gettime(clk, &ts);
    const elapsed_s = @divTrunc(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec - start_ns, std.time.ns_per_s);
    try std.testing.expect(result.timed_out);
    // 修复前会阻塞到孙进程退出（~15s）；有界拖干应在 ~3s（1s 超时 + 2s 拖干）返回
    try std.testing.expect(elapsed_s < 10);
}

// 回归：超时必须按进程组收割。子进程 fork 后 setsid 自成新进程组（pgid=pid），
// 后台孙进程继承同组——修复前 SIGKILL 只杀直接子进程，孙进程存活满 30s；
// 修复后 kill(-pid) 组杀整组，孙进程数秒内必死。孙进程 pid 由 sh 预先写入
// 固定路径，返回后轮询 /proc/<pid>/cmdline 验证（zombie/消失均算死亡）。
test "execFd timeout reaps the whole process group including grandchildren" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const linux = std.os.linux;

    const bin = try std.Io.Dir.cwd().readFileAlloc(test_threaded.io(), "/bin/sh", allocator, .limited(8 << 20));
    defer allocator.free(bin);

    // 固定 pid 文件路径：测试前删残留、结束后清理
    const pid_path = "/tmp/le-gc-pgroup-test";
    _ = linux.unlink(pid_path);
    defer _ = linux.unlink(pid_path);

    const fd = try runner.createMemfd(bin);
    defer _ = linux.close(fd);
    const script = "sleep 30 & echo $! > /tmp/le-gc-pgroup-test ; exec sleep 30";
    const argv = try LinuxCtx.buildArgv(allocator, "sh", &.{ "-c", script });
    defer LinuxCtx.freeArgv(allocator, argv);
    const envp = try runner.buildEnvp(allocator);
    defer allocator.free(envp);

    const result = try runner.execFd(allocator, fd, argv, envp, 1);
    defer allocator.free(result.output);
    try std.testing.expect(result.timed_out);

    // 读取孙进程 pid（sh 在超时杀死它之前早已写好该文件）
    const pid_fd = try std.posix.openat(std.posix.AT.FDCWD, pid_path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(pid_fd);
    var pid_buf: [32]u8 = undefined;
    const pid_len = try std.posix.read(pid_fd, &pid_buf);
    const gc_pid = std.fmt.parseInt(i32, std.mem.trim(u8, pid_buf[0..pid_len], " \t\r\n"), 10) catch
        return error.Unexpected;
    try std.testing.expect(gc_pid > 0);

    // 轮询最多 3s：/proc/<pid>/cmdline 打不开（已退出且被收殓）或读出为空
    // （zombie，SIGKILL 已送达仅剩记档）均算死亡；存活进程 cmdline 非空。
    // 修复前孙进程存活 30s，此处 3s 内必超时失败。
    var dead = false;
    var waited_ms: u32 = 0;
    while (waited_ms < 3000) : (waited_ms += 50) {
        var proc_buf: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&proc_buf, "/proc/{d}/cmdline", .{gc_pid}) catch unreachable;
        if (std.posix.openat(std.posix.AT.FDCWD, proc_path, .{ .ACCMODE = .RDONLY }, 0)) |pfd| {
            defer _ = linux.close(pfd);
            var cmd_buf: [64]u8 = undefined;
            const n = std.posix.read(pfd, &cmd_buf) catch 0;
            if (n == 0) dead = true;
        } else |_| {
            dead = true; // ENOENT：进程已彻底消失
        }
        if (dead) break;
        var req: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
    try std.testing.expect(dead);
}

test "createAnonFile leaves no path behind" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const fd = try runner.createAnonFile("data");
    defer _ = std.os.linux.close(fd);
    // fd 可读回内容（unlink 后仍持有 inode）；0.16 posix 无 pread，lseek+read 等价
    const linux = std.os.linux;
    if (linux.errno(linux.lseek(fd, 0, linux.SEEK.SET)) != .SUCCESS) return error.Unexpected;
    var buf: [8]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try std.testing.expectEqualStrings("data", buf[0..n]);
    _ = allocator;
}

// O_TMPFILE 降级层：/tmp 下打开从不落名的无名 inode，写满后 fd 可读回校验
//（memfd 与具名匿名 tmpfile 之间的中间降级档位，全生命周期零路径）。
test "createOtmpFile writes readable data with no name" {
    if (comptime !runner.is_linux) return error.SkipZigTest;
    const linux = std.os.linux;

    const fd = try runner.createOtmpFile("otmp-data");
    defer _ = linux.close(fd);
    // 无名 inode 仅由 fd 引用；0.16 posix 无 pread，lseek+read 等价
    if (linux.errno(linux.lseek(fd, 0, linux.SEEK.SET)) != .SUCCESS) return error.Unexpected;
    var buf: [16]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try std.testing.expectEqualStrings("otmp-data", buf[0..n]);
}
