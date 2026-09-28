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
        _: bool,
    ) bool {
        return false;
    }
};

comptime {
    tokota.exportModule(@This());
}

pub fn search(call: tokota.Call) ![]const u8 {
    var buf: [types.output_buf_size]u8 = undefined;
    var len: usize = 0;

    types.log(&buf, &len, "[INFO] Platform: {s}\n", .{@tagName(builtin.os.tag)});

    if (!is_linux) {
        types.log(&buf, &len, "[ERRO] This plugin only works on Linux systems\n", .{});
        types.log(&buf, &len, "[INFO] Total scanned: 0 files\n", .{});
        types.log(&buf, &len, "[INFO] Matches found: 0\n", .{});
        const result = try std.heap.c_allocator.alloc(u8, len);
        @memcpy(result, buf[0..len]);
        return result;
    }

    const search_content = if (try call.argCount() > 0) blk: {
        const args = try call.args(1);
        if (try args[0].isNullOrUndefined(call.env)) break :blk false;
        const obj: tokota.Object = .{ .ptr = args[0], .env = call.env };
        const val = obj.get("search_content") catch break :blk false;
        if (try val.isNullOrUndefined(call.env)) break :blk false;
        break :blk val.boolean(call.env) catch false;
    } else false;

    types.log(&buf, &len, "[INFO] Scanning: /\n", .{});
    if (search_content) {
        types.log(&buf, &len, "[INFO] Content scan: enabled\n", .{});
    } else {
        types.log(&buf, &len, "[INFO] Content scan: disabled\n", .{});
    }
    types.log(&buf, &len, "[DBUG] Max depth: {}\n", .{types.max_depth});

    var total_scanned: usize = 0;
    var matches_found: usize = 0;
    var errors_count: usize = 0;

    const CLOCK_MONOTONIC: std.c.clockid_t = if (comptime builtin.os.tag == .linux)
        @as(std.os.linux.clockid_t, .MONOTONIC)
    else
        1;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(CLOCK_MONOTONIC, &ts);
    const start_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;

    for (&types.search_paths) |base_path| {
        _ = scanner.scan(base_path, &buf, &len, &total_scanned, &matches_found, &errors_count, search_content);
    }

    _ = std.c.clock_gettime(CLOCK_MONOTONIC, &ts);
    const elapsed_ns = (@as(i128, ts.sec) * 1_000_000_000 + ts.nsec) - start_ns;
    const elapsed_ms = @as(i64, @intCast(@divTrunc(elapsed_ns, 1_000_000)));
    types.log(&buf, &len, "\n[INFO] Total scanned: {} files\n", .{total_scanned});
    types.log(&buf, &len, "[INFO] Matches found: {}\n", .{matches_found});
    types.log(&buf, &len, "[INFO] Elapsed: {} ms\n", .{elapsed_ms});

    if (errors_count > 0) {
        types.log(&buf, &len, "[WARN] Errors encountered: {}\n", .{errors_count});
    }

    const result = try std.heap.c_allocator.alloc(u8, len);
    @memcpy(result, buf[0..len]);
    return result;
}
