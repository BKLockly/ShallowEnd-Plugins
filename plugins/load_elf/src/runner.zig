// 纯逻辑层：不 import tokota，跨平台可单测；memfd/execveat 执行链仅 Linux 有意义。
const std = @import("std");
const builtin = @import("builtin");

pub const default_run_timeout_s: u32 = 60;
// 主仓请求级超时钳制上限 1800s，插件侧留余量
pub const max_run_timeout_s: u32 = 1700;
pub const max_output_bytes: usize = 1 << 20;

pub const is_linux = builtin.os.tag == .linux;

pub const ExecMode = enum {
    memfd,
    anon_file,

    pub fn label(self: ExecMode) []const u8 {
        return switch (self) {
            .memfd => "memfd (in-memory)",
            .anon_file => "anon-tmpfile (memfd unavailable, unlinked before exec)",
        };
    }
};

pub const ExecResult = struct {
    output: []u8,
    timed_out: bool = false,
    failed: bool = false,
    exit_code: ?u8 = null,
    raw_collected: usize = 0,
};

pub fn isElf(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF");
}

/// 把 args 文本按空白拆成 argv token。不经 shell，引号按字面量处理。
pub fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| try list.append(allocator, try allocator.dupe(u8, tok));
    return list.toOwnedSlice(allocator);
}

/// 去掉 ANSI 转义序列（CSI / 其他 ESC 序列），输出喂给前端纯文本契约。
pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b) {
            if (i + 1 < text.len and text[i + 1] == '[') {
                // CSI：跳到终止字节 0x40–0x7E
                i += 2;
                while (i < text.len) : (i += 1) {
                    if (text[i] >= 0x40 and text[i] <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            } else {
                i += 2;
            }
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// 继承宿主进程 environ（dlopen 场景 std.os.environ 未初始化，走 libc 全局），
/// 无 NO_COLOR 时追加。返回 null 结尾数组；字符串本体属 libc/静态区，仅释放数组。
pub fn buildEnvp(allocator: std.mem.Allocator) ![:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    errdefer list.deinit(allocator);
    var has_no_color = false;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        if (std.mem.startsWith(u8, std.mem.span(entry), "NO_COLOR=")) has_no_color = true;
        try list.append(allocator, entry);
    }
    if (!has_no_color) try list.append(allocator, "NO_COLOR=1");
    try list.append(allocator, null);
    return list.toOwnedSliceSentinel(allocator, null);
}

var tmp_seq: u64 = 0;

/// 临时文件名的唯一性来源（pid + 线程 id + 自增，无需密码学强度）。
fn nextSeed() u64 {
    tmp_seq +%= 1;
    return (@as(u64, @intCast(std.c.getpid())) << 32) ^ (@as(u64, std.Thread.getCurrentId()) << 16) ^ tmp_seq;
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    const linux = std.os.linux;
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        const n = @as(isize, @bitCast(rc));
        if (n <= 0) return error.FdWriteFailed;
        off += @intCast(n);
    }
}

/// memfd 承载 ELF（空名 + CLOEXEC：/proc 中仅显示 "/memfd:" 前缀），写满 bytes。
pub fn createMemfd(bytes: []const u8) !std.posix.fd_t {
    const linux = std.os.linux;
    const rc = linux.memfd_create("", linux.MFD.CLOEXEC);
    if (@as(isize, @bitCast(rc)) < 0) return error.MemfdUnavailable;
    const fd: std.posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    try writeAllFd(fd, bytes);
    return fd;
}

/// 匿名 tmpfile 承载 ELF（memfd 被禁时的降级路径）：/tmp 下 0700 创建，
/// 写满后立即 unlink——仅剩 fd 引用，被 SIGKILL 也不留路径。
pub fn createAnonFile(bytes: []const u8) !std.posix.fd_t {
    const linux = std.os.linux;
    var name_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&name_buf, "/tmp/.loadelf-{x}.bin", .{nextSeed()}) catch
        return error.TempPathOverflow;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o700);
    if (@as(isize, @bitCast(rc)) < 0) return error.TempFileUnavailable;
    const fd: std.posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    try writeAllFd(fd, bytes);
    _ = linux.unlink(path);
    return fd;
}

fn monoNs() i128 {
    // std.time 计时 API 在 0.16 移除，走 libc clock_gettime（agentscan 同款）
    const clk: std.c.clockid_t = if (comptime is_linux)
        @as(std.os.linux.clockid_t, .MONOTONIC)
    else
        1; // darwin CLOCK_MONOTONIC
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// fork + execveat 执行 fd 指向的可执行镜像，stdout/stderr 合并收集，超时 SIGKILL。
/// argv/envp 必须以 null 结尾。子进程 exec 降级链：execveat(AT_EMPTY_PATH) →
/// execve("/proc/self/fd/N")（老内核无 execveat 时跟随 procfs symlink）→
/// exit 126，父进程侧转 error.ExecFailed（fd 内容不是可执行镜像等致命场景）。
/// 全部字符串在 fork 前构建，子进程分支零分配。
pub fn execFd(
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    run_timeout_s: u32,
) !ExecResult {
    const linux = std.os.linux;

    var fds = [2]std.posix.fd_t{ -1, -1 };
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return error.PipeFailed;

    const pid = linux.fork();
    if (@as(isize, @bitCast(pid)) < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return error.ForkFailed;
    }

    if (pid == 0) {
        // 子进程：stdout/stderr → 管道，exec 仅在失败时返回（CLOEXEC fd exec 成功后自动关闭）
        _ = linux.dup2(fds[1], 1);
        _ = linux.dup2(fds[1], 2);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        _ = linux.execveat(fd, "", argv.ptr, envp.ptr, .{ .SYMLINK_NOFOLLOW = false, .EMPTY_PATH = true });
        var proc_buf: [32]u8 = undefined;
        const proc_path = std.fmt.bufPrintZ(&proc_buf, "/proc/self/fd/{d}", .{fd}) catch
            linux.exit(126);
        _ = linux.execve(proc_path.ptr, argv.ptr, envp.ptr);
        linux.exit(126);
    }

    _ = linux.close(fds[1]);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 16 * 1024);
    defer out.deinit();

    var buf: [8192]u8 = undefined;
    var timed_out = false;
    var collected: usize = 0;
    const deadline_ns = monoNs() + @as(i128, run_timeout_s) * std.time.ns_per_s;
    var eof = false;

    while (!eof) {
        const now = monoNs();
        if (now >= deadline_ns) {
            timed_out = true;
            break;
        }
        var wait_ms: i32 = @intCast(@min(@divFloor(deadline_ns - now, std.time.ns_per_ms), 1000));
        if (wait_ms <= 0) wait_ms = 1;
        var pfds = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&pfds, wait_ms) catch 0;
        if (n > 0) {
            const r = std.posix.read(fds[0], &buf) catch 0;
            if (r == 0) {
                eof = true;
            } else {
                // 超限后不再写入，但保持读循环拖干管道直到子进程退出
                const take = @min(r, max_output_bytes - collected);
                out.writer.writeAll(buf[0..take]) catch {};
                collected += take;
            }
        }
    }

    if (timed_out) _ = linux.kill(@intCast(pid), .KILL);
    // 拖干残余输出（kill 后管道里可能还有数据）
    while (true) {
        const r = std.posix.read(fds[0], &buf) catch 0;
        if (r == 0) break;
        const take = @min(r, max_output_bytes - collected);
        out.writer.writeAll(buf[0..take]) catch {};
        collected += take;
    }
    _ = linux.close(fds[0]);

    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    var exit_code: ?u8 = null;
    if (linux.W.IFEXITED(status)) exit_code = linux.W.EXITSTATUS(status);
    if (timed_out) return .{ .output = try out.toOwnedSlice(), .timed_out = true, .failed = true, .exit_code = exit_code, .raw_collected = collected };
    if (exit_code == @as(u8, 126)) return error.ExecFailed;
    return .{
        .output = try out.toOwnedSlice(),
        .failed = linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) != 0,
        .raw_collected = collected,
        .exit_code = exit_code,
    };
}
