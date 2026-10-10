const std = @import("std");
const flate = std.compress.flate;

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
