const std = @import("std");
const runner = @import("runner.zig");

test "splitTargets splits on whitespace, commas, semicolons and newlines" {
    const t = try runner.splitTargets(std.testing.allocator, "1.2.3.4, 5.6.7.0/24\nhost.example.com;;8.8.8.8\t\t10.0.0.0/8");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 5), t.len);
    try std.testing.expectEqualStrings("1.2.3.4", t[0]);
    try std.testing.expectEqualStrings("5.6.7.0/24", t[1]);
    try std.testing.expectEqualStrings("host.example.com", t[2]);
    try std.testing.expectEqualStrings("8.8.8.8", t[3]);
    try std.testing.expectEqualStrings("10.0.0.0/8", t[4]);
}

test "splitTargets of only separators yields nothing" {
    const t = try runner.splitTargets(std.testing.allocator, " \t,\n;;\r\n");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 0), t.len);
}

test "buildArgs maps options to CLI flags" {
    const args = try runner.buildArgs(std.testing.allocator, "a2a", .{
        .targets = "10.0.0.1, 192.168.1.0/24",
        .threads = 64,
        .timeout_ms = 1500,
        .skip_port_scan = true,
        .proxy = "socks5://127.0.0.1:1080",
        .verbose = true,
        .strict = true,
    });
    defer {
        for (args) |a| std.testing.allocator.free(a);
        std.testing.allocator.free(args);
    }
    const want = [_][]const u8{
        "a2a",
        "--target",
        "10.0.0.1",
        "--target",
        "192.168.1.0/24",
        "--threads",
        "64",
        "--timeout",
        "1500",
        "--skip-port-scan",
        "--proxy",
        "socks5://127.0.0.1:1080",
        "--verbose",
        "--strict",
        "--no-color",
    };
    try std.testing.expectEqual(want.len, args.len);
    for (want, args) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "buildArgs skips zero/default values" {
    const args = try runner.buildArgs(std.testing.allocator, "llm", .{
        .targets = "127.0.0.1",
        .threads = 0,
        .timeout_ms = 0,
        .proxy = "",
        .strict = true, // 非 a2a 子命令也会带上，由上游拒绝；调用侧负责 gate
    });
    defer {
        for (args) |a| std.testing.allocator.free(a);
        std.testing.allocator.free(args);
    }
    const want = [_][]const u8{ "llm", "--target", "127.0.0.1", "--strict", "--no-color" };
    try std.testing.expectEqual(want.len, args.len);
    for (want, args) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "buildArgs errors on empty targets" {
    try std.testing.expectError(error.NoTargets, runner.buildArgs(std.testing.allocator, "scan", .{
        .targets = " ,\t;;\n ",
    }));
}

test "stripAnsi removes CSI sequences" {
    const s = try runner.stripAnsi(std.testing.allocator, "\x1b[1m[MCP]\x1b[0m 1.2.3.4:443\x1b[32;1m ok\x1b[0m\n");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[MCP] 1.2.3.4:443 ok\n", s);
}

test "stripAnsi keeps plain text intact" {
    const s = try runner.stripAnsi(std.testing.allocator, "plain [INFO] text \x07 bell");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("plain [INFO] text \x07 bell", s);
}

test "decompressPayload round-trips gzip bytes" {
    // 真实 gzip 魔数头：空 gzip 流 + 手工压缩的 "hello agentscan"
    // 这里用 std.compress.flate 压缩出口做往返验证
    const allocator = std.testing.allocator;
    const text = "hello agentscan\n[MCP] 1.2.3.4:443\n";

    var compressed: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &compressed.writer,
        &window,
        .gzip,
        std.compress.flate.Compress.Options.default,
    );
    try compressor.writer.writeAll(text);
    try compressor.finish();

    const round = try runner.decompressPayload(allocator, compressed.written());
    defer allocator.free(round);
    try std.testing.expectEqualStrings(text, round);
}
