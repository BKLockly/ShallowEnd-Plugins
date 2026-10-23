const std = @import("std");
const builtin = @import("builtin");
const tokota = @import("tokota");
const runner = @import("runner.zig");

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

pub fn execElf(call: tokota.Call) !tokota.Promise {
    if (comptime !runner.is_linux) {
        return error.LinuxOnly;
    }
    const allocator = std.heap.c_allocator;
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    // file 参数经 payload 解码后以 Buffer 形态出现在 elf_file（文件名被覆盖）
    const elf_val = params.get("elf_file") catch return error.ElfFileRequired;
    if (try elf_val.isNullOrUndefined(call.env)) return error.ElfFileRequired;
    const elf_buf = try elf_val.buffer(call.env);
    const elf_bytes = elf_buf.data;

    const args_text = try optString(call, params, "args", allocator);
    defer if (args_text) |t| allocator.free(t);

    // argv[0] 决议见 runner.resolveArgv0：显式参数 > 文件名（新 payload 契约
    // 保留在 <key>_name）> "elf"。busybox 多合一目标机必须匹配 applet 名。
    const argv0_explicit = try optString(call, params, "argv0", allocator);
    defer if (argv0_explicit) |t| allocator.free(t);
    const elf_filename = try optString(call, params, "elf_file_name", allocator);
    defer if (elf_filename) |t| allocator.free(t);

    var timeout_s: u32 = runner.default_run_timeout_s;
    if (params.getT("timeout", f64)) |fv| {
        if (fv > 0) timeout_s = @intFromFloat(@min(fv, runner.max_run_timeout_s));
    } else |_| {}

    if (!runner.isElf(elf_bytes)) {
        return error.NotAnElf;
    }

    // 耗时的 fork+waitpid 放到 libuv 线程池（AsyncWorker）执行，导出 Promise，
    // 不阻塞目标机 Node 事件循环；fd 创建（memfd/otmp/降级 tmpfile）留在同步段。
    const task = try ElfTask.prepare(allocator, elf_bytes, args_text, argv0_explicit, elf_filename, timeout_s);
    errdefer task.deinit(false);

    const promise, const deferred = try call.env.promise();
    task.deferred = deferred;
    task.work = try call.env.asyncWorkerT(task, ElfTask.execute, ElfTask.complete, .{
        .name = "load-elf-exec",
    });
    errdefer task.work.delete(call.env) catch {};

    try task.work.schedule(call.env);
    return promise;
}

// 一次执行任务的全部堆上状态（跨 AsyncWorker 线程传递）。
const ElfTask = struct {
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    mode: runner.ExecMode,
    elf_size: usize,
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    timeout_s: u32,
    deferred: tokota.Deferred = undefined,
    work: tokota.async.Worker = undefined,
    // execute 产物（complete resolve 后所有权移交 JS 侧字符串），
    // 失败时为 null，由 complete 走 reject。
    output: ?[]const u8 = null,

    // 同步段：创建承载 ELF 的 fd（降级链 memfd → O_TMPFILE → 匿名 tmpfile，
    // 全程不落可复现路径）、组装 argv/envp。argv[0] 决议顺序见 runner.resolveArgv0。
    fn prepare(
        allocator: std.mem.Allocator,
        elf_bytes: []const u8,
        args_text: ?[]const u8,
        argv0_explicit: ?[]const u8,
        elf_filename: ?[]const u8,
        timeout_s: u32,
    ) !*ElfTask {
        const linux = std.os.linux;

        const fd, const mode = blk: {
            if (runner.createMemfd(elf_bytes)) |fd| {
                break :blk .{ fd, runner.ExecMode.memfd };
            } else |_| {}
            if (runner.createOtmpFile(elf_bytes)) |fd| {
                break :blk .{ fd, runner.ExecMode.otmp };
            } else |_| {}
            const fd = try runner.createAnonFile(elf_bytes);
            break :blk .{ fd, runner.ExecMode.anon_file };
        };
        errdefer _ = linux.close(fd);

        const arg_tokens = try runner.splitArgs(allocator, args_text orelse "");
        defer {
            for (arg_tokens) |t| allocator.free(t);
            allocator.free(arg_tokens);
        }

        // null 结尾 argv：[argv0, tokens..., null]
        var argv = try allocator.allocSentinel(?[*:0]const u8, arg_tokens.len + 1, null);
        errdefer allocator.free(argv);
        const argv0 = try runner.resolveArgv0(allocator, argv0_explicit, elf_filename);
        errdefer allocator.free(argv0);
        argv[0] = argv0.ptr;
        for (arg_tokens, 0..) |t, i| argv[i + 1] = (try allocator.dupeZ(u8, t)).ptr;

        const envp = try runner.buildEnvp(allocator);
        errdefer allocator.free(envp);

        const task = try allocator.create(ElfTask);
        task.* = .{
            .allocator = allocator,
            .fd = fd,
            .mode = mode,
            .elf_size = elf_bytes.len,
            .argv = argv,
            .envp = envp,
            .timeout_s = timeout_s,
        };
        return task;
    }

    // 释放全部堆上状态；resolved 为 true 表示 output 字符串已移交 JS 侧。
    fn deinit(self: *ElfTask, resolved: bool) void {
        const allo = self.allocator;
        const linux = std.os.linux;
        if (self.output) |o| {
            if (!resolved) allo.free(o);
        }
        for (self.argv) |a| {
            // span 恢复 [:0]u8 sentinel 形态，free 才能按 len+1 释放（dupeZ 分配量）
            if (a) |z| allo.free(std.mem.span(@constCast(z)));
        }
        allo.free(self.argv);
        allo.free(self.envp);
        _ = linux.close(self.fd);
        allo.destroy(self);
    }

    // libuv 线程池：fork + waitpid 执行，组装 [LEVEL] 契约输出。
    fn execute(self: *ElfTask) !void {
        const allocator = self.allocator;

        const result = runner.execFd(allocator, self.fd, self.argv, self.envp, self.timeout_s) catch
            return error.ExecFailed;
        defer allocator.free(result.output);

        const clean = runner.stripAnsi(allocator, result.output) catch
            return error.NormalizeFailed;
        defer allocator.free(clean);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const header = std.fmt.allocPrint(
            allocator,
            "[INFO] load_elf exec: mode={s} size={d}B timeout={d}s raw={d}\n",
            .{ self.mode.label(), self.elf_size, self.timeout_s, result.raw_collected },
        ) catch return error.OutOfMemory;
        defer allocator.free(header);
        try out.appendSlice(allocator, header);

        if (clean.len > 0) {
            try out.appendSlice(allocator, clean);
            if (clean[clean.len - 1] != '\n') try out.append(allocator, '\n');
            if (clean.len >= runner.max_output_bytes) {
                try out.appendSlice(allocator, "[WARN] output truncated\n");
            }
        } else {
            try out.appendSlice(allocator, "[WARN] no output produced\n");
        }

        if (result.timed_out) {
            const line = std.fmt.allocPrint(
                allocator,
                "[WARN] process exceeded run timeout ({d}s) and was killed\n",
                .{self.timeout_s},
            ) catch return error.OutOfMemory;
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        } else if (result.failed) {
            const line = std.fmt.allocPrint(
                allocator,
                "[WARN] exited with code {d}\n",
                .{result.exit_code orelse 0},
            ) catch return error.OutOfMemory;
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        } else {
            const line = std.fmt.allocPrint(
                allocator,
                "[INFO] exit code: {d}\n",
                .{result.exit_code orelse 0},
            ) catch return error.OutOfMemory;
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
        self.output = try out.toOwnedSlice(allocator);
    }

    // JS 线程：resolve/reject Promise 并释放任务状态。
    fn complete(self: *ElfTask, env: tokota.Env, err: anyerror!void) !void {
        if (err) |_| {
            defer self.deinit(true);
            if (self.output) |o| {
                try self.deferred.resolve(env, o);
            } else {
                try self.deferred.reject(env, try env.err("load_elf failed", {}));
            }
        } else |_| {
            defer self.deinit(false);
            return self.deferred.reject(env, try env.err("load_elf failed: napi error", {}));
        }
    }
};
