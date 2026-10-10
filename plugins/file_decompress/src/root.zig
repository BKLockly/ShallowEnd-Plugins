const std = @import("std");
const tokota = @import("tokota");
const flate = std.compress.flate;
const Io = std.Io;

comptime {
    tokota.exportModule(@This());
}

const c_allocator = std.heap.c_allocator;

/// 读写缓冲 32 KiB + flate 窗口 32 KiB，全链路流式，常数内存。
const io_buf_len = 32 * 1024;
/// 单条失败明细最多展示行数
const max_shown_failures = 20;

/// 所有文件操作均为同步调用，单线程 Io 即可。
var threaded: Io.Threaded = .init_single_threaded;

// name 必须是 [:0]const u8：tokota Object.get 的 key 需要哨兵终止，字面量可隐式推断
fn getStringParam(params: anytype, env: anytype, comptime name: [:0]const u8) ![]u8 {
    const val = try params.get(name);
    return try (try val.stringCoerce(env)).stringAlloc(env, c_allocator);
}

fn kb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024.0;
}

fn outOfMemory() []const u8 {
    return "[ERRO] Out of memory";
}

fn opErr(comptime action: []const u8, path: []const u8, err: anyerror) []const u8 {
    return std.fmt.allocPrint(
        c_allocator,
        "[ERRO] Failed to " ++ action ++ " \"{s}\": {s}",
        .{ path, @errorName(err) },
    ) catch outOfMemory();
}

/// 解压 .gz 文件为源文件（流式）。
///
/// 参数：
/// - source_path: 要解压的 .gz 文件路径
/// - target_path: 输出的源文件路径
pub fn decompress(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const source_path = try getStringParam(params, call.env, "source_path");
    defer c_allocator.free(source_path);
    const target_path = try getStringParam(params, call.env, "target_path");
    defer c_allocator.free(target_path);

    if (std.mem.eql(u8, source_path, target_path))
        return "[ERRO] Source and target paths must be different";

    const io_ = threaded.io();
    const cwd = Io.Dir.cwd();

    var source_file = cwd.openFile(io_, source_path, .{}) catch |err|
        return opErr("open source file", source_path, err);
    defer source_file.close(io_);

    const source_size: u64 = if (source_file.stat(io_)) |st| st.size else |_| 0;

    var target_file = cwd.createFile(io_, target_path, .{}) catch |err|
        return opErr("create target file", target_path, err);
    defer target_file.close(io_);
    // 失败时清理半成品输出
    var target_ok = false;
    defer if (!target_ok) cwd.deleteFile(io_, target_path) catch {};

    var read_buf: [io_buf_len]u8 = undefined;
    var write_buf: [io_buf_len]u8 = undefined;
    var window: [flate.max_window_len]u8 = undefined;

    var source_reader = source_file.reader(io_, &read_buf);
    var decompressor: flate.Decompress = .init(&source_reader.interface, .gzip, &window);
    var target_writer = target_file.writer(io_, &write_buf);

    const total_out = decompressor.reader.streamRemaining(&target_writer.interface) catch |err|
        return opErr("decompress", source_path, err);
    target_writer.interface.flush() catch |err|
        return opErr("write target file", target_path, err);
    target_ok = true;

    return std.fmt.allocPrint(
        c_allocator,
        "[INFO] Decompression complete\n" ++
            "    Source: {s} ({d:.1} KB)\n" ++
            "    Target: {s} ({d:.1} KB)",
        .{ source_path, kb(source_size), target_path, kb(total_out) },
    ) catch outOfMemory();
}

/// 将 .tar.gz 归档解包到目标目录。
///
/// 保留文件可执行位；已存在的文件跳过并在结果中列明；目录不存在时自动
/// 创建；拒绝归档内路径逃逸目标目录（tar-slip 防护）。
///
/// 参数：
/// - source_path: 要解包的 .tar.gz 文件路径
/// - target_path: 目标目录路径
pub fn decompressArchive(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const source_path = try getStringParam(params, call.env, "source_path");
    defer c_allocator.free(source_path);
    const target_path = try getStringParam(params, call.env, "target_path");
    defer c_allocator.free(target_path);

    const io_ = threaded.io();
    const cwd = Io.Dir.cwd();

    var source_file = cwd.openFile(io_, source_path, .{}) catch |err|
        return opErr("open archive", source_path, err);
    defer source_file.close(io_);

    const source_size: u64 = if (source_file.stat(io_)) |st| st.size else |_| 0;

    cwd.createDirPath(io_, target_path) catch |err|
        return opErr("create target directory", target_path, err);

    var target_dir = cwd.openDir(io_, target_path, .{}) catch |err|
        return opErr("open target directory", target_path, err);
    defer target_dir.close(io_);

    var diag: std.tar.Diagnostics = .{ .allocator = c_allocator };
    defer diag.deinit();

    var read_buf: [io_buf_len]u8 = undefined;
    var window: [flate.max_window_len]u8 = undefined;
    var source_reader = source_file.reader(io_, &read_buf);
    var decompressor: flate.Decompress = .init(&source_reader.interface, .gzip, &window);

    std.tar.extract(io_, target_dir, &decompressor.reader, .{
        .mode_mode = .executable_bit_only,
        .diagnostics = &diag,
    }) catch |err| return opErr("extract archive", source_path, err);

    var aw: std.Io.Writer.Allocating = .init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.print(
        "[INFO] Archive extracted\n" ++
            "    Source: {s} ({d:.1} KB)\n" ++
            "    Target: {s}\n" ++
            "    Entries: {d}\n",
        .{ source_path, kb(source_size), target_path, diag.entries },
    ) catch return outOfMemory();
    if (diag.errors.items.len > 0) {
        w.print(
            "[WARN] {d} entries skipped or failed\n",
            .{diag.errors.items.len},
        ) catch return outOfMemory();
        const shown = @min(diag.errors.items.len, max_shown_failures);
        for (diag.errors.items[0..shown]) |item| {
            const line = switch (item) {
                .unable_to_create_file => |e| std.fmt.allocPrint(
                    c_allocator,
                    "    {s}: {s}",
                    .{ e.file_name, @errorName(e.code) },
                ),
                .unable_to_create_sym_link => |e| std.fmt.allocPrint(
                    c_allocator,
                    "    {s} -> {s}: {s}",
                    .{ e.file_name, e.link_name, @errorName(e.code) },
                ),
                .unsupported_file_type => |e| std.fmt.allocPrint(
                    c_allocator,
                    "    {s}: unsupported type {c}",
                    .{ e.file_name, @intFromEnum(e.file_type) },
                ),
                .components_outside_stripped_prefix => |e| std.fmt.allocPrint(
                    c_allocator,
                    "    {s}: path escapes target directory",
                    .{e.file_name},
                ),
            } catch null;
            if (line) |l| {
                w.print("{s}\n", .{l}) catch {
                    c_allocator.free(l);
                    return outOfMemory();
                };
                c_allocator.free(l);
            }
        }
        if (diag.errors.items.len > shown) {
            w.print(
                "    ... and {d} more\n",
                .{diag.errors.items.len - shown},
            ) catch return outOfMemory();
        }
    }
    return aw.toOwnedSlice() catch outOfMemory();
}
