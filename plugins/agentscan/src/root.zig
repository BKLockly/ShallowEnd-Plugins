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

fn runSub(call: tokota.Call, subcommand: []const u8, allow_strict: bool, allow_honeypots: bool) ![]const u8 {
    if (comptime builtin.os.tag != .linux) {
        return "[ERRO] agentscan payload targets Linux only\n";
    }
    const allocator = std.heap.c_allocator;
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const targets_text = (try optString(call, params, "targets", allocator)) orelse
        return "[ERRO] targets is required (IP / CIDR / domain / host:port, separated by comma or whitespace)\n";
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
            return "[ERRO] no valid target parsed from input\n";
        }
        return "[ERRO] failed to build command line\n";
    };
    defer {
        for (cmd_args) |a| allocator.free(a);
        allocator.free(cmd_args);
    }

    // 解压内嵌 payload → 落地临时文件（0700）
    const bin_bytes = runner.decompressPayload(allocator, payload.bin) catch
        return "[ERRO] failed to decompress embedded payload\n";
    defer allocator.free(bin_bytes);

    var name_buf: [64]u8 = undefined;
    const tmp_dir = std.fmt.bufPrintZ(
        &name_buf,
        "/tmp/.agentscan-{x}.d",
        .{nextTmpSeed()},
    ) catch return "[ERRO] failed to build temp path\n";
    const linux = std.os.linux;
    _ = linux.mkdir(tmp_dir, 0o700);

    var bin_buf: [96]u8 = undefined;
    const bin_path = std.fmt.bufPrintZ(&bin_buf, "{s}/payload.bin", .{tmp_dir}) catch
        return "[ERRO] failed to build temp path\n";
    {
        const fd = std.posix.openat(
            linux.AT.FDCWD,
            bin_path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o700,
        ) catch return "[ERRO] failed to write payload to temp file\n";
        var written: usize = 0;
        while (written < bin_bytes.len) {
            const rc = linux.write(fd, bin_bytes.ptr + written, bin_bytes.len - written);
            if (@as(isize, @bitCast(rc)) <= 0) break;
            written += rc;
        }
        _ = linux.close(fd);
        if (written < bin_bytes.len) return "[ERRO] failed to write payload to temp file\n";
    }

    const argv = try allocator.alloc([]const u8, cmd_args.len + 1);
    defer allocator.free(argv);
    argv[0] = bin_path;
    @memcpy(argv[1..], cmd_args);

    // cwd 圈定：上游会往 CWD 落 html/txt 报告，chdir 进临时目录后统一清理
    const result = runner.exec(allocator, argv, runner.default_run_timeout_s, tmp_dir) catch
        return "[ERRO] failed to execute agentscan payload\n";
    defer allocator.free(result.output);

    // 清理临时目录（含报告文件）；/bin/rm 缺失时为 best-effort
    _ = linux.unlink(bin_path);
    if (runner.exec(allocator, &.{ "/bin/rm", "-rf", tmp_dir }, 10, null)) |res| {
        allocator.free(res.output);
    } else |_| {}

    const clean = runner.stripAnsi(allocator, result.output) catch
        return "[ERRO] failed to normalize output\n";
    defer allocator.free(clean);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const header = std.fmt.allocPrint(
        allocator,
        "[INFO] agentscan {s} ({s})\n",
        .{ subcommand, upstream_credit },
    ) catch return "[ERRO] out of memory\n";
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
    return out.toOwnedSlice(allocator);
}

pub fn scan(call: tokota.Call) ![]const u8 {
    return runSub(call, "scan", false, false);
}

pub fn mcp(call: tokota.Call) ![]const u8 {
    return runSub(call, "mcp", false, true);
}

pub fn a2a(call: tokota.Call) ![]const u8 {
    return runSub(call, "a2a", true, false);
}

pub fn llm(call: tokota.Call) ![]const u8 {
    return runSub(call, "llm", false, false);
}
