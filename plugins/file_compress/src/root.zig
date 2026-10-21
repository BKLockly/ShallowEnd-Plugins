const std = @import("std");
const tokota = @import("tokota");
const flate = std.compress.flate;
const Io = std.Io;
const pack = @import("pack.zig");

comptime {
    tokota.exportModule(@This());
}

const c_allocator = std.heap.c_allocator;

/// 所有文件操作均为同步调用，单线程 Io 即可。
var threaded: Io.Threaded = .init_single_threaded;

// name 必须是 [:0]const u8：tokota Object.get 的 key 需要哨兵终止，字面量可隐式推断
fn getStringParam(params: anytype, env: anytype, comptime name: [:0]const u8) ![]u8 {
    const val = try params.get(name);
    return try (try val.stringCoerce(env)).stringAlloc(env, c_allocator);
}

fn getOptStringParam(params: anytype, env: anytype, comptime name: [:0]const u8) !?[]u8 {
    const val = params.get(name) catch return null;
    if (try val.isNullOrUndefined(env)) return null;
    return try (try val.stringCoerce(env)).stringAlloc(env, c_allocator);
}

fn parseLevel(raw: []const u8) ?flate.Compress.Options {
    if (std.ascii.eqlIgnoreCase(raw, "fastest")) return .fastest;
    if (std.ascii.eqlIgnoreCase(raw, "default")) return .default;
    if (std.ascii.eqlIgnoreCase(raw, "best")) return .best;
    return null;
}

fn outOfMemory() []const u8 {
    return "[ERRO] Out of memory";
}

/// 压缩单个文件为 .gz（流式）。
///
/// 参数：
/// - source_path: 源文件路径
/// - target_path: 输出的 .gz 路径
/// - level: 可选，fastest | default | best，默认 default
pub fn compress(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const source_path = try getStringParam(params, call.env, "source_path");
    defer c_allocator.free(source_path);
    const target_path = try getStringParam(params, call.env, "target_path");
    defer c_allocator.free(target_path);

    var level: flate.Compress.Options = .default;
    if (try getOptStringParam(params, call.env, "level")) |raw| {
        defer c_allocator.free(raw);
        level = parseLevel(raw) orelse
            return "[ERRO] Invalid level, expected fastest | default | best";
    }

    if (std.mem.eql(u8, source_path, target_path))
        return "[ERRO] Source and target paths must be different";

    const io_ = threaded.io();
    const cwd = Io.Dir.cwd();

    var source_file = cwd.openFile(io_, source_path, .{}) catch |err|
        return pack.opErr(c_allocator, "open source file", source_path, err) catch outOfMemory();
    defer source_file.close(io_);

    var target_file = cwd.createFile(io_, target_path, .{}) catch |err|
        return pack.opErr(c_allocator, "create target file", target_path, err) catch outOfMemory();
    defer target_file.close(io_);
    // 失败时清理半成品输出
    var target_ok = false;
    defer if (!target_ok) cwd.deleteFile(io_, target_path) catch {};

    var read_buf: [pack.io_buf_len]u8 = undefined;
    var write_buf: [pack.io_buf_len]u8 = undefined;
    var window: [flate.max_window_len]u8 = undefined;

    var source_reader = source_file.reader(io_, &read_buf);
    var target_writer = target_file.writer(io_, &write_buf);
    var compressor = flate.Compress.init(
        &target_writer.interface,
        &window,
        .gzip,
        level,
    ) catch |err| return pack.opErr(c_allocator, "initialize gzip compressor", target_path, err) catch outOfMemory();

    const total_in = source_reader.interface.streamRemaining(&compressor.writer) catch |err|
        return pack.opErr(c_allocator, "read source file", source_path, err) catch outOfMemory();

    compressor.finish() catch |err| return pack.opErr(c_allocator, "finalize gzip stream", target_path, err) catch outOfMemory();
    target_writer.interface.flush() catch |err|
        return pack.opErr(c_allocator, "write target file", target_path, err) catch outOfMemory();
    target_ok = true;

    const target_size: u64 = if (target_file.stat(io_)) |st| st.size else |_| 0;

    return std.fmt.allocPrint(
        c_allocator,
        "[INFO] Compression complete\n" ++
            "    Source: {s} ({d:.1} KB)\n" ++
            "    Target: {s} ({d:.1} KB)\n" ++
            "    Ratio: {d:.1}% reduction",
        .{
            source_path,
            pack.kb(total_in),
            target_path,
            pack.kb(target_size),
            pack.reduction(total_in, target_size),
        },
    ) catch outOfMemory();
}

/// 将目录递归打包为 .tar.gz（流式：walk → tar → gzip → fd）。
///
/// 归档内条目路径相对 source_path；目录条目先于其内容；符号链接保留为
/// link 条目；fifo/socket/设备文件跳过并在结果中列明。
///
/// 参数：
/// - source_path: 源目录路径
/// - target_path: 输出的 .tar.gz 路径
/// - level: 可选，fastest | default | best，默认 fastest
pub fn compressDir(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    const source_path = try getStringParam(params, call.env, "source_path");
    defer c_allocator.free(source_path);
    const target_path = try getStringParam(params, call.env, "target_path");
    defer c_allocator.free(target_path);

    var level: flate.Compress.Options = .fastest;
    if (try getOptStringParam(params, call.env, "level")) |raw| {
        defer c_allocator.free(raw);
        level = parseLevel(raw) orelse
            return "[ERRO] Invalid level, expected fastest | default | best";
    }

    return pack.packDir(c_allocator, threaded.io(), source_path, target_path, level) catch outOfMemory();
}
