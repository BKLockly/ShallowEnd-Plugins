const std = @import("std");
const builtin = @import("builtin");
const tokota = @import("tokota");
const payload = @import("payload");
const runner = @import("runner.zig");

const upstream_credit = "upstream: https://github.com/7anX/AgentScan (MIT, vendored)";

/// 临时文件名的唯一性来源（pid + 线程 id + 自增，无需密码学强度）。
var tmp_seq: u64 = 0;

fn nextTmpSeed() u64 {
    tmp_seq +%= 1;
    return (@as(u64, @intCast(std.c.getpid())) << 32) ^ (@as(u64, std.Thread.getCurrentId()) << 16) ^ tmp_seq;
}

comptime {
    tokota.exportModule(@This());
}

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

fn runSub(call: tokota.Call, subcommand: []const u8, allow_strict: bool, allow_honeypots: bool) !tokota.Promise {
    if (comptime builtin.os.tag != .linux) {
        return error.LinuxOnly;
    }
    const allocator = std.heap.c_allocator;
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const targets_text = (try optString(call, params, "targets", allocator)) orelse
        return error.TargetsRequired;
    defer allocator.free(targets_text);

    const proxy: ?[]const u8 = try optString(call, params, "proxy", allocator);
    defer if (proxy) |p| allocator.free(p);

    var threads: ?u32 = null;
    if (params.getT("threads", f64)) |fv| {
        if (fv > 0 and fv <= 65535) threads = @intFromFloat(fv);
    } else |_| {}
    var timeout_ms: ?u32 = null;
    if (params.getT("timeout", f64)) |fv| {
        if (fv > 0) timeout_ms = @intFromFloat(fv);
    } else |_| {}
    const skip_port_scan = params.getT("skip_port_scan", bool) catch false;
    const verbose = params.getT("verbose", bool) catch false;
    const strict = allow_strict and (params.getT("strict", bool) catch false);
    const exclude_honeypots = allow_honeypots and (params.getT("exclude_honeypots", bool) catch false);

    const cmd_args = runner.buildArgs(allocator, subcommand, .{
        .targets = targets_text,
        .threads = threads,
        .timeout_ms = timeout_ms,
        .skip_port_scan = skip_port_scan,
        .proxy = proxy,
        .verbose = verbose,
        .strict = strict,
        .exclude_honeypots = exclude_honeypots,
    }) catch |e| {
        if (e == error.NoTargets) {
            return error.NoValidTargets;
        }
        return error.BuildArgsFailed;
    };
    defer {
        for (cmd_args) |a| allocator.free(a);
        allocator.free(cmd_args);
    }

    // 解压内嵌 payload → 落地临时文件（0700）；耗时的 fork+waitpid 放到
    // libuv 线程池（AsyncWorker）执行，导出 Promise，不阻塞 Node 事件循环
    const task = try ScanTask.prepare(allocator, subcommand, cmd_args);
    errdefer task.deinit(false);

    const promise, const deferred = try call.env.promise();
    task.deferred = deferred;
    task.work = try call.env.asyncWorkerT(task, ScanTask.execute, ScanTask.complete, .{
        .name = "agentscan-run",
    });
    errdefer task.work.delete(call.env) catch {};

    try task.work.schedule(call.env);
    return promise;
}
// 一次扫描任务的全部堆上状态（跨 AsyncWorker 线程传递）。
const ScanTask = struct {
    allocator: std.mem.Allocator,
    subcommand: []const u8,
    cmd_args: [][]const u8,
    argv: [][]const u8,
    tmp_dir: [:0]const u8,
    bin_path: [:0]const u8,
    deferred: tokota.Deferred = undefined,
    work: tokota.async.Worker = undefined,
    // execute 产物（complete resolve 后所有权移交 JS 侧字符串），
    // 失败时为 null，改用 err_msg。
    output: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,

    // 同步段：解压 payload、写临时文件、组装 argv。所有字段堆上分配。
    fn prepare(allocator: std.mem.Allocator, subcommand: []const u8, cmd_args: [][]const u8) !*ScanTask {
        const linux = std.os.linux;

        const bin_bytes = runner.decompressPayload(allocator, payload.bin) catch
            return error.PayloadDecompressFailed;
        defer allocator.free(bin_bytes);

        var name_buf: [64]u8 = undefined;
        const tmp_dir = std.fmt.bufPrintZ(
            &name_buf,
            "/tmp/.agentscan-{x}.d",
            .{nextTmpSeed()},
        ) catch return error.TempPathOverflow;
        _ = linux.mkdir(tmp_dir, 0o700);

        var bin_buf: [96]u8 = undefined;
        const bin_path = std.fmt.bufPrintZ(&bin_buf, "{s}/payload.bin", .{tmp_dir}) catch
            return error.TempPathOverflow;

        const fd = std.posix.openat(
            linux.AT.FDCWD,
            bin_path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o700,
        ) catch return error.PayloadWriteFailed;
        var written: usize = 0;
        while (written < bin_bytes.len) {
            const rc = linux.write(fd, bin_bytes.ptr + written, bin_bytes.len - written);
            if (@as(isize, @bitCast(rc)) <= 0) break;
            written += rc;
        }
        _ = linux.close(fd);
        if (written < bin_bytes.len) return error.PayloadWriteFailed;

        const argv = try allocator.alloc([]const u8, cmd_args.len + 1);
        argv[0] = try allocator.dupeZ(u8, bin_path);
        for (cmd_args, 0..) |a, idx| argv[idx + 1] = a;

        const task = try allocator.create(ScanTask);
        task.* = .{
            .allocator = allocator,
            .subcommand = try allocator.dupe(u8, subcommand),
            .cmd_args = cmd_args,
            .argv = argv,
            .tmp_dir = try allocator.dupeZ(u8, tmp_dir),
            .bin_path = try allocator.dupeZ(u8, bin_path),
        };
        return task;
    }

    // 释放全部堆上状态；resolved 为 true 表示 output 字符串已移交 JS 侧。
    fn deinit(self: *ScanTask, resolved: bool) void {
        const allo = self.allocator;
        if (self.output) |o| {
            if (!resolved) allo.free(o);
        }
        if (self.err_msg) |m| allo.free(m);
        for (self.cmd_args) |a| allo.free(a);
        allo.free(self.cmd_args);
        for (self.argv) |a| allo.free(a);
        allo.free(self.argv);
        allo.free(self.tmp_dir);
        allo.free(self.bin_path);
        allo.free(self.subcommand);
        allo.destroy(self);
    }

    // libuv 线程池：fork + waitpid 执行扫描（最长 600s），组装输出文本。
    fn execute(self: *ScanTask) !void {
        const allocator = self.allocator;
        const linux = std.os.linux;

        const result = runner.exec(allocator, self.argv, runner.default_run_timeout_s, self.tmp_dir) catch
            return error.ExecFailed;
        defer allocator.free(result.output);

        // 清理临时目录（含报告文件）；/bin/rm 缺失时为 best-effort
        _ = linux.unlink(self.bin_path);
        if (runner.exec(allocator, &.{ "/bin/rm", "-rf", self.tmp_dir }, 10, null)) |res| {
            allocator.free(res.output);
        } else |_| {}

        const clean = runner.stripAnsi(allocator, result.output) catch
            return error.NormalizeFailed;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const header = std.fmt.allocPrint(
            allocator,
            "[INFO] agentscan {s} ({s})\n",
            .{ self.subcommand, upstream_credit },
        ) catch return error.OutOfMemory;
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
        if (clean.len > 0) {
            try out.appendSlice(allocator, clean);
            if (clean[clean.len - 1] != '\n') try out.append(allocator, '\n');
        } else {
            try out.appendSlice(allocator, "[WARN] no output produced\n");
        }
        if (result.timed_out) {
            try out.appendSlice(allocator, "[WARN] process exceeded run timeout and was killed\n");
        } else if (result.failed) {
            try out.appendSlice(allocator, "[WARN] agentscan exited non-zero\n");
        }
        self.output = try out.toOwnedSlice(allocator);
    }

    // JS 线程：resolve/reject Promise 并释放任务状态。
    fn complete(self: *ScanTask, env: tokota.Env, err: anyerror!void) !void {
        if (err) |_| {
            defer self.deinit(true);
            if (self.output) |o| {
                try self.deferred.resolve(env, o);
            } else {
                try self.deferred.reject(env, try env.err("agentscan failed", {}));
            }
        } else |_| {
            defer self.deinit(false);
            return self.deferred.reject(env, try env.err("agentscan failed: napi error", {}));
        }
    }
};

pub fn scan(call: tokota.Call) !tokota.Promise {
    return runSub(call, "scan", false, false);
}

pub fn mcp(call: tokota.Call) !tokota.Promise {
    return runSub(call, "mcp", false, true);
}

pub fn a2a(call: tokota.Call) !tokota.Promise {
    return runSub(call, "a2a", true, false);
}

pub fn llm(call: tokota.Call) !tokota.Promise {
    return runSub(call, "llm", false, false);
}
