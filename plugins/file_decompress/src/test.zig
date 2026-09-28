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

    const compressed_data = compressed.written();
    try std.testing.expect(compressed_data.len > 0);

    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var in: std.Io.Reader = .fixed(compressed_data);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var decompressor: flate.Decompress = .init(&in, .gzip, &decompress_buf);
    const decompressed_len = try decompressor.reader.streamRemaining(&aw.writer);
    const decompressed = aw.written();

    try std.testing.expectEqual(original.len, decompressed_len);
    try std.testing.expectEqualStrings(original, decompressed);
}
