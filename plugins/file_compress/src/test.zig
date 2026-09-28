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
