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
