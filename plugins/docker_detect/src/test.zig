const std = @import("std");

test "formatInt works correctly" {
    var buf: [16]u8 = undefined;

    const result0 = formatInt(&buf, 0);
    try std.testing.expectEqualSlices(u8, "0", result0);

    const result1 = formatInt(&buf, 1);
    try std.testing.expectEqualSlices(u8, "1", result1);

    const result42 = formatInt(&buf, 42);
    try std.testing.expectEqualSlices(u8, "42", result42);

    const result100 = formatInt(&buf, 100);
    try std.testing.expectEqualSlices(u8, "100", result100);
}

/// Format integer to string, returns slice into buf
fn formatInt(buf: []u8, val: u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = buf.len;
    var v = val;
    while (v > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[i..];
}
