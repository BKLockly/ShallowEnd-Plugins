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
const link_buf_len = std.fs.max_path_bytes;
/// 单条失败明细最多展示行数
const max_shown_failures = 20;
/// 失败明细最多保留条数（防失控内存）
const max_stored_failures = 50;

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

fn kb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024.0;
}

fn reduction(in: u64, out: u64) f64 {
    if (in == 0) return 0.0;
    return 100.0 - (@as(f64, @floatFromInt(out)) / @as(f64, @floatFromInt(in)) * 100.0);
}

fn mtimeSeconds(st: Io.File.Stat) u64 {
    const sec = st.mtime.toSeconds();
    return if (sec < 0) 0 else @intCast(sec);
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

const Failures = struct {
    items: std.ArrayList([]u8) = .empty,
    count: usize = 0,

    fn deinit(self: *Failures) void {
        for (self.items.items) |item| c_allocator.free(item);
        self.items.deinit(c_allocator);
    }

    fn add(self: *Failures, name: []const u8, err: anyerror) void {
        self.count += 1;
        if (self.items.items.len >= max_stored_failures) return;
        const msg = std.fmt.allocPrint(
            c_allocator,
            "{s}: {s}",
            .{ name, @errorName(err) },
        ) catch return;
        self.items.append(c_allocator, msg) catch {
            c_allocator.free(msg);
        };
    }
};

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
        return opErr("open source file", source_path, err);
    defer source_file.close(io_);

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
    var target_writer = target_file.writer(io_, &write_buf);
    var compressor = flate.Compress.init(
        &target_writer.interface,
        &window,
        .gzip,
        level,
    ) catch |err| return opErr("initialize gzip compressor", target_path, err);

    const total_in = source_reader.interface.streamRemaining(&compressor.writer) catch |err|
        return opErr("read source file", source_path, err);

    compressor.finish() catch |err| return opErr("finalize gzip stream", target_path, err);
    target_writer.interface.flush() catch |err|
        return opErr("write target file", target_path, err);
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
            kb(total_in),
            target_path,
            kb(target_size),
            reduction(total_in, target_size),
        },
    ) catch outOfMemory();
}

const PackCounts = struct {
    files: usize = 0,
    dirs: usize = 0,
    links: usize = 0,
    skipped: usize = 0,
};

/// ustar 路径上限（name 100 + prefix 155）内能否放下该路径，判定逻辑对齐
/// std.tar.Writer.Header.setPath：末段必须在 name 内、前缀可拆进 prefix。
fn ustarPathFits(path: []const u8) bool {
    if (path.len <= 100) return true;
    if (path.len > 255) return false;
    const sep = std.mem.lastIndexOfScalar(u8, path[0..@min(155, path.len)], '/') orelse return false;
    return (path.len - sep - 1) <= 100;
}

/// GNU 扩展头（gnu_long_name 'L' / gnu_long_link 'K'）。
/// busybox tar 只认 GNU 惯例的 "././@LongLink" name；std.tar.Writer 写的是
/// 空 name，busybox 会把扩展头当普通条目导致后续流整体错位，故长路径时
/// 绕开 std 的回退路径手动写。
fn gnuLongEntry(w: *std.tar.Writer, typeflag: std.tar.Writer.Header.FileType, data: []const u8) !void {
    var hdr: std.tar.Writer.Header = .init(typeflag);
    @memcpy(hdr.name[0.."././@LongLink".len], "././@LongLink");
    try hdr.setSize(data.len);
    try hdr.write(w.underlying_writer);
    try w.underlying_writer.writeAll(data);
    const rem: usize = @intCast(data.len % 512);
    if (rem != 0) try w.underlying_writer.splatByteAll(0, 512 - rem);
}

fn writeRealHeader(
    w: *std.tar.Writer,
    typeflag: std.tar.Writer.Header.FileType,
    name: []const u8,
    link_name: []const u8,
    size: u64,
    mode: u32,
    mtime: u64,
) !void {
    var hdr: std.tar.Writer.Header = .init(typeflag);
    // name 只放得下前 100 字节；支持 GNU 扩展头的读取器会用 L 数据覆盖
    const nm = name[0..@min(name.len, 100)];
    @memcpy(hdr.name[0..nm.len], nm);
    try hdr.setSize(size);
    try hdr.setMtime(mtime);
    if (mode != 0) try hdr.setMode(mode);
    if (typeflag == .symbolic_link) try hdr.setLinkname(link_name[0..@min(link_name.len, 100)]);
    try hdr.write(w.underlying_writer);
}

const EntryOptions = struct {
    mode: u32 = 0,
    mtime: u64 = 0,
};

fn writeDirEntry(w: *std.tar.Writer, path: []const u8, opts: EntryOptions) !void {
    if (ustarPathFits(path)) return w.writeDir(path, .{ .mode = opts.mode, .mtime = opts.mtime });
    try gnuLongEntry(w, .gnu_long_name, path);
    try writeRealHeader(w, .directory, path, "", 0, opts.mode, opts.mtime);
}

fn writeLinkEntry(w: *std.tar.Writer, path: []const u8, link_name: []const u8, opts: EntryOptions) !void {
    if (ustarPathFits(path) and link_name.len <= 100)
        return w.writeLink(path, link_name, .{ .mode = opts.mode, .mtime = opts.mtime });
    if (!ustarPathFits(path)) try gnuLongEntry(w, .gnu_long_name, path);
    if (link_name.len > 100) try gnuLongEntry(w, .gnu_long_link, link_name);
    try writeRealHeader(w, .symbolic_link, path, link_name, 0, opts.mode, opts.mtime);
}

fn writeFileEntry(
    w: *std.tar.Writer,
    path: []const u8,
    size: u64,
    reader: *Io.Reader,
    opts: EntryOptions,
    buf: []u8,
) !void {
    if (ustarPathFits(path)) {
        return w.writeFileStream(path, size, reader, .{ .mode = opts.mode, .mtime = opts.mtime });
    }
    try gnuLongEntry(w, .gnu_long_name, path);
    try writeRealHeader(w, .regular, path, "", size, opts.mode, opts.mtime);
    var remaining = size;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, buf.len));
        try reader.readSliceAll(buf[0..chunk]);
        try w.underlying_writer.writeAll(buf[0..chunk]);
        remaining -= chunk;
    }
    const rem: usize = @intCast(size % 512);
    if (rem != 0) try w.underlying_writer.splatByteAll(0, 512 - rem);
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

    const io_ = threaded.io();
    const cwd = Io.Dir.cwd();

    var source_dir = cwd.openDir(io_, source_path, .{ .iterate = true }) catch |err|
        return opErr("open source directory", source_path, err);
    defer source_dir.close(io_);

    var target_file = cwd.createFile(io_, target_path, .{}) catch |err|
        return opErr("create target file", target_path, err);
    defer target_file.close(io_);
    var target_ok = false;
    defer if (!target_ok) cwd.deleteFile(io_, target_path) catch {};

    var write_buf: [io_buf_len]u8 = undefined;
    var read_buf: [io_buf_len]u8 = undefined;
    var window: [flate.max_window_len]u8 = undefined;
    var target_writer = target_file.writer(io_, &write_buf);
    var compressor = flate.Compress.init(
        &target_writer.interface,
        &window,
        .gzip,
        level,
    ) catch |err| return opErr("initialize gzip compressor", target_path, err);
    var tar_w: std.tar.Writer = .{ .underlying_writer = &compressor.writer };

    var walker = source_dir.walk(c_allocator) catch |err|
        return opErr("scan source directory", source_path, err);
    defer walker.deinit();

    var counts: PackCounts = .{};
    var total_in: u64 = 0;
    var failures: Failures = .{};
    defer failures.deinit();

    while (true) {
        const entry = walker.next(io_) catch |err| {
            // 遍历中断：已写入条目均完整，归档结构有效但内容不全
            failures.add("<walk>", err);
            break;
        } orelse break;

        switch (entry.kind) {
            .directory => {
                // 头部写入失败分两类：WriteFailed（落盘失败，可能已有部分字节）中止并删除；
                // 其余（路径放不下等纯计算失败）未写入任何字节，跳过续走
                writeDirEntry(&tar_w, entry.path, .{}) catch |err| {
                    if (err == error.WriteFailed) return abortPacking(io_, cwd, target_path, entry.path, err);
                    failures.add(entry.path, err);
                    continue;
                };
                counts.dirs += 1;
            },
            .file => {
                var f = entry.dir.openFile(io_, entry.basename, .{}) catch |err| {
                    failures.add(entry.path, err);
                    continue;
                };
                defer f.close(io_);
                const st = f.stat(io_) catch |err| {
                    failures.add(entry.path, err);
                    continue;
                };
                var fr = f.reader(io_, &read_buf);
                // 内容中途失败无法回补 tar 填充，归档即损坏，只能中止并删除
                writeFileEntry(&tar_w, entry.path, st.size, &fr.interface, .{
                    .mode = @intCast(st.permissions.toMode() & 0o7777),
                    .mtime = mtimeSeconds(st),
                }, &read_buf) catch |err| return abortPacking(io_, cwd, target_path, entry.path, err);
                counts.files += 1;
                total_in += st.size;
            },
            .sym_link => {
                var link_buf: [link_buf_len]u8 = undefined;
                const link_len = entry.dir.readLink(io_, entry.basename, &link_buf) catch |err| {
                    failures.add(entry.path, err);
                    continue;
                };
                writeLinkEntry(&tar_w, entry.path, link_buf[0..link_len], .{}) catch |err| {
                    if (err == error.WriteFailed) return abortPacking(io_, cwd, target_path, entry.path, err);
                    failures.add(entry.path, err);
                    continue;
                };
                counts.links += 1;
            },
            else => counts.skipped += 1,
        }
    }

    tar_w.finishPedantically() catch |err|
        return abortPacking(io_, cwd, target_path, "<finish>", err);
    compressor.finish() catch |err|
        return abortPacking(io_, cwd, target_path, "<finish>", err);
    target_writer.interface.flush() catch |err|
        return abortPacking(io_, cwd, target_path, "<finish>", err);
    target_ok = true;

    const target_size: u64 = if (target_file.stat(io_)) |st| st.size else |_| 0;

    var aw: std.Io.Writer.Allocating = .init(c_allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.print(
        "[INFO] Directory packed\n" ++
            "    Source: {s} ({d:.1} KB)\n" ++
            "    Target: {s} ({d:.1} KB)\n" ++
            "    Ratio: {d:.1}% reduction\n" ++
            "    Entries: {d} files, {d} dirs, {d} links\n",
        .{
            source_path,
            kb(total_in),
            target_path,
            kb(target_size),
            reduction(total_in, target_size),
            counts.files,
            counts.dirs,
            counts.links,
        },
    ) catch return outOfMemory();
    if (counts.skipped > 0) {
        w.print(
            "[WARN] Skipped {d} unsupported entries (fifo/socket/device)\n",
            .{counts.skipped},
        ) catch return outOfMemory();
    }
    if (failures.count > 0) {
        w.print("[WARN] {d} entries failed\n", .{failures.count}) catch return outOfMemory();
        const shown = @min(failures.items.items.len, max_shown_failures);
        for (failures.items.items[0..shown]) |msg| {
            w.print("    {s}\n", .{msg}) catch return outOfMemory();
        }
        if (failures.count > shown) {
            w.print("    ... and {d} more\n", .{failures.count - shown}) catch return outOfMemory();
        }
    }
    return aw.toOwnedSlice() catch outOfMemory();
}

fn abortPacking(io_: Io, cwd: Io.Dir, target_path: []const u8, entry: []const u8, err: anyerror) []const u8 {
    cwd.deleteFile(io_, target_path) catch {};
    return std.fmt.allocPrint(
        c_allocator,
        "[ERRO] Packing aborted at \"{s}\" ({s}), partial archive deleted",
        .{ entry, @errorName(err) },
    ) catch outOfMemory();
}
