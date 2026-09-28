const std = @import("std");
const tokota = @import("tokota");
const flate = std.compress.flate;
const linux = std.os.linux;

const SEEK_SET = 0;
const SEEK_END = 2;

comptime {
    tokota.exportModule(@This());
}

pub fn decompress(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);
    const allocator = std.heap.c_allocator;
    const source_val = try params.get("source_path");
    const target_val = try params.get("target_path");
    const source_path = try (try source_val.stringCoerce(call.env)).stringAlloc(call.env, allocator);
    defer allocator.free(source_path);
    const target_path = try (try target_val.stringCoerce(call.env)).stringAlloc(call.env, allocator);
    defer allocator.free(target_path);

    const source_fd = try std.posix.openat(
        linux.AT.FDCWD,
        source_path,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    errdefer _ = linux.close(source_fd);

    const file_size = linux.lseek(source_fd, 0, SEEK_END);
    if (@as(isize, @bitCast(file_size)) < 0) {
        _ = linux.close(source_fd);
        return "[ERRO] Failed to get file size";
    }
    _ = linux.lseek(source_fd, 0, SEEK_SET);

    const compressed_data = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(compressed_data);

    const bytes_read = try std.posix.read(source_fd, compressed_data);
    _ = linux.close(source_fd);
    if (bytes_read != compressed_data.len) {
        return "[ERRO] Short read from source file";
    }

    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var in: std.Io.Reader = .fixed(compressed_data);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var decompressor: flate.Decompress = .init(&in, .gzip, &decompress_buf);
    const decompressed_len = try decompressor.reader.streamRemaining(&aw.writer);
    const decompressed_data = aw.written();

    const target_fd = try std.posix.openat(
        linux.AT.FDCWD,
        target_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    errdefer _ = linux.close(target_fd);

    var written: usize = 0;
    while (written < decompressed_data.len) {
        const rc = linux.write(target_fd, decompressed_data.ptr + written, decompressed_data.len - written);
        if (@as(isize, @bitCast(rc)) < 0) {
            _ = linux.close(target_fd);
            return "[ERRO] Failed to write output file";
        }
        written += rc;
    }
    _ = linux.close(target_fd);

    const in_kb = @as(f64, @floatFromInt(compressed_data.len)) / 1024.0;
    const out_kb = @as(f64, @floatFromInt(decompressed_len)) / 1024.0;

    return std.fmt.allocPrint(allocator,
        "[INFO] Decompression complete\n" ++
        "    Source: {s} ({d:.1} KB)\n" ++
        "    Target: {s} ({d:.1} KB)\n" ++
        "    Size: {d:.1} KB -> {d:.1} KB",
        .{ source_path, in_kb, target_path, out_kb, in_kb, out_kb },
    );
}
