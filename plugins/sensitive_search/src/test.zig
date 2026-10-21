const std = @import("std");
const types = @import("types.zig");

test "filename patterns match expected labels" {
    const testing = std.testing;
    const cases = [_]struct { name: []const u8, expect: []const u8 }{
        .{ .name = "server.pem", .expect = "certificate/key file" },
        .{ .name = "private.key", .expect = "certificate/key file" },
        .{ .name = "cert.crt", .expect = "certificate file" },
        .{ .name = "Test.env", .expect = "environment variable file" },
        .{ .name = "id_rsa", .expect = "private key (RSA)" },
        .{ .name = "id_ed25519", .expect = "private key (Ed25519)" },
        .{ .name = "database.db", .expect = "database file" },
        .{ .name = "users.sqlite", .expect = "SQLite database" },
        .{ .name = "credentials.json", .expect = "credentials file" },
        .{ .name = ".env", .expect = "environment variable file" },
    };
    for (cases) |c| {
        var matched = false;
        for (&types.filename_patterns) |p| {
            if (std.mem.indexOf(u8, c.name, p.substr) != null) {
                try testing.expectEqualStrings(c.expect, p.label);
                matched = true;
                break;
            }
        }
        try testing.expect(matched);
    }
}

test "non-sensitive filenames do not match" {
    const testing = std.testing;
    const safe = [_][]const u8{ "readme.txt", "main.go", "index.html", "script.js", "styles.css", "photo.jpg", "video.mp4" };
    for (safe) |name| {
        for (&types.filename_patterns) |p| {
            try testing.expect(std.mem.indexOf(u8, name, p.substr) == null);
        }
    }
}

test "content patterns are compile-time valid" {
    const testing = std.testing;
    try testing.expect(types.content_patterns.len > 0);
    for (&types.content_patterns) |p| {
        try testing.expect(p.substr.len > 0);
        try testing.expect(p.label.len > 0);
    }
}

test "isSkippedPath skips system trees but preserves /usr/local exception" {
    const testing = std.testing;
    // /usr 需穿过以抵达例外：/usr 本身放行、/usr/share 内部跳过、
    // /usr/local 例外连同其内部放行
    try testing.expect(!types.isSkippedPath("/usr"));
    try testing.expect(types.isSkippedPath("/usr/share/doc"));
    try testing.expect(types.isSkippedPath("/usr/lib/x86_64-linux-gnu"));
    try testing.expect(!types.isSkippedPath("/usr/local"));
    try testing.expect(!types.isSkippedPath("/usr/local/share/app"));
    // segment 精确匹配：/libc /library 不被 /lib 规则误伤
    try testing.expect(types.isSkippedPath("/lib"));
    try testing.expect(types.isSkippedPath("/lib64/x86_64"));
    try testing.expect(!types.isSkippedPath("/libc"));
    try testing.expect(!types.isSkippedPath("/library"));
    // 其余规则与高价值目录不受影响
    try testing.expect(types.isSkippedPath("/snap/core/current"));
    try testing.expect(types.isSkippedPath("/var/cache/apt/archives"));
    try testing.expect(types.isSkippedPath("/var/lib/docker/overlay2/x/diff"));
    try testing.expect(types.isSkippedPath("/var/lib/containerd/io.containerd.snapshotter"));
    try testing.expect(!types.isSkippedPath("/var/lib"));
    try testing.expect(!types.isSkippedPath("/var/lib/postgresql/16/main"));
    try testing.expect(!types.isSkippedPath("/home/u/app/.env"));
    try testing.expect(!types.isSkippedPath("/etc"));
    try testing.expect(!types.isSkippedPath("/opt/tools"));
}

test "log caps writes at tail reserve and marks truncation" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var truncated = false;

    types.log(&buf, &len, &truncated, "[WARN] Found: /a\n", .{});
    try testing.expect(!truncated);
    try testing.expectEqualStrings("[WARN] Found: /a\n", buf[0..len]);

    // 灌到触及尾部保留线：写入停止并置位
    while (!truncated) {
        types.log(&buf, &len, &truncated, "0123456789abcdef\n", .{});
    }
    try testing.expect(len <= 256 - types.output_tail_reserve);

    // 保留区足够写下截断标记（writeTruncationMarker 绕过 log 的保留线）
    const before = len;
    types.writeTruncationMarker(&buf, &len);
    try testing.expect(len == before + types.truncation_marker.len);
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "Output truncated") != null);
}

test "isSkipDir matches basenames exactly" {
    const testing = std.testing;
    try testing.expect(types.isSkipDir("node_modules"));
    try testing.expect(types.isSkipDir("proc"));
    try testing.expect(!types.isSkipDir("node_modules2"));
    try testing.expect(!types.isSkipDir("src"));
}
