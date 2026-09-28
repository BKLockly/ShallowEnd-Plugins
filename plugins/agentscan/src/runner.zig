// 纯逻辑层：不 import tokota / payload，可在无 Node 的环境下单测。
const std = @import("std");
const flate = std.compress.flate;

pub const default_run_timeout_s: u32 = 600;

pub const Options = struct {
    targets: []const u8,
    threads: ?u32 = null,
    timeout_ms: ?u32 = null,
    skip_port_scan: bool = false,
    proxy: ?[]const u8 = null,
    verbose: bool = false,
    strict: bool = false,
    exclude_honeypots: bool = false,
};

/// 把用户输入按空白/逗号/分号/换行拆成目标 token。
pub fn splitTargets(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,;");
    while (it.next()) |tok| try list.append(allocator, tok);
    return list.toOwnedSlice(allocator);
}

/// 组装 agentscan 命令行参数（不含 argv[0]）。
/// 契约：返回的每个字符串都由调用方 free（静态字面量也做了 dupe）。
pub fn buildArgs(allocator: std.mem.Allocator, subcommand: []const u8, opts: Options) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |a| allocator.free(a);
        args.deinit(allocator);
    }

    const push = struct {
        fn f(al: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
            try list.append(al, try al.dupe(u8, s));
        }
    }.f;

    try push(allocator, &args, subcommand);

    const targets = try splitTargets(allocator, opts.targets);
    defer allocator.free(targets);
    if (targets.len == 0) return error.NoTargets;
    for (targets) |t| {
        try push(allocator, &args, "--target");
        try push(allocator, &args, t);
    }

    if (opts.threads) |n| {
        if (n > 0) {
            try push(allocator, &args, "--threads");
            try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{n}));
        }
    }
    if (opts.timeout_ms) |ms| {
        if (ms > 0) {
            try push(allocator, &args, "--timeout");
            try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{ms}));
        }
    }
    if (opts.skip_port_scan) try push(allocator, &args, "--skip-port-scan");
    if (opts.proxy) |p| {
        if (p.len > 0) {
            try push(allocator, &args, "--proxy");
            try push(allocator, &args, p);
        }
    }
    if (opts.verbose) try push(allocator, &args, "--verbose");
    if (opts.strict) try push(allocator, &args, "--strict");
    if (opts.exclude_honeypots) try push(allocator, &args, "--exclude-honeypots");
    try push(allocator, &args, "--no-color");
    return args.toOwnedSlice(allocator);
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

/// 解压内嵌的 gzip payload（构建期由 go build + gzip 产出）。
pub fn decompressPayload(allocator: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in, .gzip, &window);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try dec.reader.appendRemainingUnlimited(allocator, &out);
    return out.toOwnedSlice(allocator);
}

pub const ExecResult = struct {
    output: []u8,
    timed_out: bool = false,
    failed: bool = false,
};

fn monoNs() i128 {
    // std.time 计时 API 在 0.16 移除，走 libc clock_gettime（sensitive_search 同款）
    const clk: std.c.clockid_t = if (comptime @import("builtin").os.tag == .linux)
        @as(std.os.linux.clockid_t, .MONOTONIC)
    else
        1; // darwin CLOCK_MONOTONIC
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// fork + execve 执行 payload，stdout/stderr 合并收集，超时 SIGKILL。
/// argv[0] 必须是可执行文件路径；cwd 非空时子进程先 chdir（上游会往 CWD 落报告文件，
/// 传专用临时目录可把产物圈住）。所有字符串在 fork 前构建，子进程分支零分配。
pub fn exec(allocator: std.mem.Allocator, argv: []const []const u8, run_timeout_s: u32, cwd: ?[:0]const u8) !ExecResult {
    const linux = std.os.linux;

    var argv_z = try allocator.alloc([:0]u8, argv.len);
    defer {
        for (argv_z) |z| allocator.free(z);
        allocator.free(argv_z);
    }
    for (argv, 0..) |a, i| argv_z[i] = try allocator.dupeZ(u8, a);

    var argv_c = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer allocator.free(argv_c);
    for (argv_z, 0..) |z, i| argv_c[i] = z.ptr;

    var env_c = try allocator.allocSentinel(?[*:0]const u8, 1, null);
    defer allocator.free(env_c);
    env_c[0] = "NO_COLOR=1";

    var fds = [2]std.posix.fd_t{ -1, -1 };
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return error.PipeFailed;

    const pid = linux.fork();
    if (@as(isize, @bitCast(pid)) < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return error.ForkFailed;
    }

    if (pid == 0) {
        // 子进程：stdout/stderr → 管道，execve 仅在失败时返回
        if (cwd) |c| _ = linux.chdir(c.ptr);
        _ = linux.dup2(fds[1], 1);
        _ = linux.dup2(fds[1], 2);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        _ = linux.execve(argv_z[0].ptr, @ptrCast(argv_c.ptr), @ptrCast(env_c.ptr));
        linux.exit(127);
    }

    _ = linux.close(fds[1]);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 16 * 1024);
    defer out.deinit();

    var buf: [8192]u8 = undefined;
    var timed_out = false;
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
                out.writer.writeAll(buf[0..r]) catch {};
            }
        }
    }

    if (timed_out) _ = linux.kill(@intCast(pid), .KILL);
    // 拖干残余输出（kill 后管道里可能还有数据）
    while (true) {
        const r = std.posix.read(fds[0], &buf) catch 0;
        if (r == 0) break;
        out.writer.writeAll(buf[0..r]) catch {};
    }
    _ = linux.close(fds[0]);

    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const failed = timed_out or
        (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) != 0);

    return .{
        .output = try out.toOwnedSlice(),
        .timed_out = timed_out,
        .failed = failed,
    };
}
