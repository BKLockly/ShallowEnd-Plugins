const std = @import("std");
const flate = std.compress.flate;
const pack = @import("pack.zig");

var test_threaded: std.Io.Threaded = .init_single_threaded;

/// 确定性内容模式：逐字节各异且跨 32KB io 缓冲边界无周期性
fn testContentByte(i: usize) u8 {
    return @truncate(i *% 2654435761 +% 0x9e3779b9);
}

var test_dir_seq: u32 = 0;

// compressDir 全链路（walk → tar → gzip → 文件）回归：超长路径走 GNU 扩展头
// 分支时，拷贝缓冲此前与 reader 内部缓冲共用（read_buf），readSliceAll 读进
// 自身导致归档内容错乱。内容 70KB（> 32KB io 缓冲）强制多次 refill 以放大
// 破坏面；相对路径 281 字节 > ustar 255 触发长路径分支，单段 90 字节保证
// macOS/Linux 文件系统都能创建。
test "compressDir packs long paths through gnu entries without corrupting content" {
    const allocator = std.testing.allocator;
    const io_ = test_threaded.io();
    const cwd: std.Io.Dir = .cwd();

    const seg = "d" ** 90;
    const rel_dirs = seg ++ "/" ++ seg ++ "/" ++ seg;
    const rel_file = rel_dirs ++ "/long.bin"; // 281 字节 > ustar 上限 255
    test_dir_seq += 1;
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/zfc-test-{x}-{x}", .{
        @as(u32, @truncate(std.Thread.getCurrentId())),
        test_dir_seq,
    });
    var dir_buf: [512]u8 = undefined;
    var file_buf: [512]u8 = undefined;
    var gz_buf: [512]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&dir_buf, "{s}/src/{s}", .{ base, rel_dirs });
    const file_path = try std.fmt.bufPrint(&file_buf, "{s}/long.bin", .{src_dir});
    const gz_path = try std.fmt.bufPrint(&gz_buf, "{s}/out.tar.gz", .{base});
    // 供收尾逐层 rmdir 的父目录视图（都是 dir_buf 的切片）
    const d2 = src_dir[0 .. src_dir.len - seg.len - 1];
    const d1 = d2[0 .. d2.len - seg.len - 1];
    const src_root = d1[0 .. d1.len - seg.len - 1];

    const content_len: usize = 70 * 1024;
    try cwd.createDirPath(io_, src_dir);
    {
        var f = try cwd.createFile(io_, file_path, .{});
        defer f.close(io_);
        // 拷贝源与 writer 内部缓冲必须独立（@memcpy 会拒绝别名参数）
        var data_buf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var fw = f.writer(io_, &wbuf);
        var i: usize = 0;
        while (i < content_len) {
            const n = @min(data_buf.len, content_len - i);
            for (data_buf[0..n], 0..) |*b, k| b.* = testContentByte(i + k);
            try fw.interface.writeAll(data_buf[0..n]);
            i += n;
        }
        try fw.interface.flush();
    }
    defer {
        cwd.deleteFile(io_, file_path) catch {};
        cwd.deleteFile(io_, gz_path) catch {};
        cwd.deleteDir(io_, src_dir) catch {};
        cwd.deleteDir(io_, d2) catch {};
        cwd.deleteDir(io_, d1) catch {};
        cwd.deleteDir(io_, src_root) catch {};
        cwd.deleteDir(io_, base) catch {};
    }

    var src_buf: [64]u8 = undefined;
    const src_path = try std.fmt.bufPrint(&src_buf, "{s}/src", .{base});
    const result = try pack.packDir(allocator, io_, src_path, gz_path, .fastest);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "[INFO] Directory packed"));
    try std.testing.expect(std.mem.indexOf(u8, result, "Entries: 1 files, 3 dirs, 0 links") != null);

    // gunzip → tar 迭代：3 个目录条目 + 长路径文件条目，内容逐字节比对
    const gz_bytes = try cwd.readFileAlloc(io_, gz_path, allocator, .limited(4 << 20));
    defer allocator.free(gz_bytes);

    var gun: std.Io.Writer.Allocating = .init(allocator);
    defer gun.deinit();
    var gz_in: std.Io.Reader = .fixed(gz_bytes);
    var dbuf: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&gz_in, .gzip, &dbuf);
    _ = try dec.reader.streamRemaining(&gun.writer);

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tar_in: std.Io.Reader = .fixed(gun.written());
    var it: std.tar.Iterator = .init(&tar_in, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    const e0 = (try it.next()).?;
    try std.testing.expectEqual(std.tar.FileKind.directory, e0.kind);
    const e1 = (try it.next()).?;
    try std.testing.expectEqual(std.tar.FileKind.directory, e1.kind);
    const e2 = (try it.next()).?;
    try std.testing.expectEqual(std.tar.FileKind.directory, e2.kind);

    const e3 = (try it.next()).?;
    try std.testing.expectEqual(std.tar.FileKind.file, e3.kind);
    try std.testing.expectEqualStrings(rel_file, e3.name);
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    try it.streamRemaining(e3, &content.writer);
    try std.testing.expectEqual(@as(usize, content_len), content.written().len);
    for (content.written(), 0..) |b, i| {
        try std.testing.expectEqual(testContentByte(i), b);
    }

    try std.testing.expectEqual(@as(?std.tar.Iterator.File, null), try it.next());
}

test "gzip output has correct magic header" {
    const allocator = std.testing.allocator;
    const original = "Hello, World! gzip test.";

    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
    defer compressed.deinit();

    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(
        &compressed.writer,
        &compress_buf,
        .gzip,
        flate.Compress.Options.default,
    );
    try compressor.writer.writeAll(original);
    try compressor.finish();

    const data = compressed.written();
    try std.testing.expect(data.len > 0);
    try std.testing.expectEqual(@as(u8, 0x1f), data[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), data[1]);
    try std.testing.expectEqual(@as(u8, 0x08), data[2]);
}

// compressDir 产物的内存 round-trip：tar → gzip → gunzip → 逐条目比对。
// 覆盖目录/文件/符号链接/超长路径（gnu 扩展头）四类条目。
test "tar.gz round trip preserves entries" {
    const allocator = std.testing.allocator;
    const long_dir = "b" ** 200;
    const long_path = long_dir ++ "/long.txt";

    var tar_buf: std.Io.Writer.Allocating = .init(allocator);
    defer tar_buf.deinit();
    var tar_w: std.tar.Writer = .{ .underlying_writer = &tar_buf.writer };
    try tar_w.writeDir("docs", .{ .mode = 0o755 });
    try tar_w.writeFileBytes("docs/a.txt", "hello archive", .{ .mode = 0o644 });
    try tar_w.writeLink("docs/link", "a.txt", .{});
    try tar_w.writeFileBytes(long_path, "x" ** 700, .{});
    try tar_w.finishPedantically();

    // Compress.init 要求底层 writer 已有容量，Allocating 需 initCapacity 预分配
    var gz_buf = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
    defer gz_buf.deinit();
    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&gz_buf.writer, &compress_buf, .gzip, .fastest);
    try compressor.writer.writeAll(tar_buf.written());
    try compressor.finish();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var gz_in: std.Io.Reader = .fixed(gz_buf.written());
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var decompressor: flate.Decompress = .init(&gz_in, .gzip, &decompress_buf);
    const n = try decompressor.reader.streamRemaining(&out.writer);
    try std.testing.expectEqual(tar_buf.written().len, n);
    try std.testing.expectEqualSlices(u8, tar_buf.written(), out.written());

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tar_in: std.Io.Reader = .fixed(out.written());
    var it: std.tar.Iterator = .init(&tar_in, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    const e0 = (try it.next()).?;
    try std.testing.expectEqual(std.tar.FileKind.directory, e0.kind);
    try std.testing.expectEqualStrings("docs", e0.name);

    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("docs/a.txt", e1.name);
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    try it.streamRemaining(e1, &content.writer);
    try std.testing.expectEqualStrings("hello archive", content.written());

    const e2 = (try it.next()).?;
    try std.testing.expectEqual(std.tar.FileKind.sym_link, e2.kind);
    try std.testing.expectEqualStrings("a.txt", e2.link_name);

    const e3 = (try it.next()).?;
    try std.testing.expectEqualStrings(long_path, e3.name);
    var content2: std.Io.Writer.Allocating = .init(allocator);
    defer content2.deinit();
    try it.streamRemaining(e3, &content2.writer);
    try std.testing.expectEqual(@as(usize, 700), content2.written().len);

    try std.testing.expectEqual(@as(?std.tar.Iterator.File, null), try it.next());
}
