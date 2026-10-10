const std = @import("std");
const flate = std.compress.flate;

test "decompress gzip output matches original" {
    const allocator = std.testing.allocator;
    const original = "Hello, World! gzip decompress test.";

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

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(compressed.written());
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var decompressor: flate.Decompress = .init(&in, .gzip, &decompress_buf);
    const n = try decompressor.reader.streamRemaining(&out.writer);
    try std.testing.expectEqual(original.len, n);
    try std.testing.expectEqualStrings(original, out.written());
}

// decompressArchive 消费侧的内存 round-trip：tar → gzip → gunzip → Iterator 比对，
// 并验证 gzip 尾部多余的零填充不会污染条目流。
test "gzipped tar stream iterates cleanly" {
    const allocator = std.testing.allocator;

    var tar_buf: std.Io.Writer.Allocating = .init(allocator);
    defer tar_buf.deinit();
    var tar_w: std.tar.Writer = .{ .underlying_writer = &tar_buf.writer };
    try tar_w.writeFileBytes("top.txt", "top-level file", .{ .mode = 0o600 });
    try tar_w.writeFileBytes("nested/data.bin", "\x00\x01\x02\x03", .{});
    try tar_w.finishPedantically();

    // Compress.init 要求底层 writer 已有容量，Allocating 需 initCapacity 预分配
    var gz_buf = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
    defer gz_buf.deinit();
    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&gz_buf.writer, &compress_buf, .gzip, .default);
    try compressor.writer.writeAll(tar_buf.written());
    try compressor.finish();

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var gz_in: std.Io.Reader = .fixed(gz_buf.written());
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var decompressor: flate.Decompress = .init(&gz_in, .gzip, &decompress_buf);

    var it: std.tar.Iterator = .init(&decompressor.reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    const e0 = (try it.next()).?;
    try std.testing.expectEqualStrings("top.txt", e0.name);
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    try it.streamRemaining(e0, &content.writer);
    try std.testing.expectEqualStrings("top-level file", content.written());

    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("nested/data.bin", e1.name);

    try std.testing.expectEqual(@as(?std.tar.Iterator.File, null), try it.next());
}
