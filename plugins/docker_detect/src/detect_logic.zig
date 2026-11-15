// 纯逻辑层：不 import tokota，信号判定可在任意平台单测（LES matcher.zig 同款分层）。
const std = @import("std");

pub const CgroupResult = struct {
    found: bool,
    pattern: []const u8,
    confidence: u8,
    hint: []const u8,
};

/// 对 /proc/1/cgroup 内容做模式匹配（v1.2.x 一贯语义）。
/// cgroup v2 统一层级下（Docker 19+ / K8s 默认）容器内通常只有 `0::/` 一行，
/// 传统 /docker/ 模式全部落空（v3.1.0 在真机 Docker 29.4 上确定容器只得 55 分
/// 的主因）——单独出现时给弱分 +10：宿主 systemd 的 pid1 通常是
/// `0::/init.scope` 不会误中，裸 init 宿主误中权重也压不过 20 分阈值。
pub fn analyzeCgroup(data: []const u8) CgroupResult {
    if (std.mem.indexOf(u8, data, "/docker/") != null) {
        return .{ .found = true, .pattern = "/docker/", .confidence = 35, .hint = "docker" };
    } else if (std.mem.indexOf(u8, data, "docker-") != null) {
        return .{ .found = true, .pattern = "docker-", .confidence = 35, .hint = "docker" };
    } else if (std.mem.indexOf(u8, data, "/lxc/") != null) {
        return .{ .found = true, .pattern = "/lxc/", .confidence = 20, .hint = "lxc" };
    } else if (std.mem.indexOf(u8, data, "/kubepods") != null) {
        return .{ .found = true, .pattern = "/kubepods", .confidence = 25, .hint = "kubernetes" };
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "0::/")) {
            return .{ .found = true, .pattern = "0::/ (cgroup v2 unified)", .confidence = 10, .hint = "" };
        }
    }
    return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };
}

pub const MountResult = struct {
    docker_found: bool,
    root_overlay: bool,
    overlay_generic: bool,
    confidence: u8,
};

/// 对 /proc/self/mountinfo 内容判定容器信号。与 v3.1.0 的差异：
/// 根挂载（mountpoint == "/"）fstype=overlay 从泛化 substring +10 提为
/// 确定性信号 +25（cgroup v2 时代 Docker/K8s/containerd/podman 通用，
/// systemd-detect-virt 同款判据）；泛化 overlay substring 只在根挂载
/// 非 overlay 时保留 +10（宿主上 bind-mount 的 overlay 目录不再误加分）。
pub fn analyzeMountinfo(data: []const u8) MountResult {
    const docker_found = std.mem.indexOf(u8, data, "docker") != null;
    const root_overlay = rootMountFstypeEql(data, "overlay");
    const overlay_generic = !root_overlay and std.mem.indexOf(u8, data, "overlay") != null;

    var confidence: u8 = 0;
    if (docker_found) confidence += 15;
    if (root_overlay) confidence += 25;
    if (overlay_generic) confidence += 10;
    return .{
        .docker_found = docker_found,
        .root_overlay = root_overlay,
        .overlay_generic = overlay_generic,
        .confidence = confidence,
    };
}

/// mountinfo 行格式：
///   `id parent maj:min root mountpoint opts... - fstype source super...`
/// 找 mountpoint 为 "/" 的行，返回其 fstype 是否等于 expected。
/// 根挂载行一般是首行，但契约上不保证顺序，故逐行扫描。
pub fn rootMountFstypeEql(data: []const u8, expected: []const u8) bool {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        var left = std.mem.splitScalar(u8, line[0..sep], ' ');
        var idx: usize = 0;
        var mountpoint: []const u8 = "";
        while (left.next()) |f| : (idx += 1) {
            if (idx == 4) mountpoint = f;
        }
        if (!std.mem.eql(u8, mountpoint, "/")) continue;
        var right = std.mem.splitScalar(u8, line[sep + 3 ..], ' ');
        const fstype = right.next() orelse continue;
        if (fstype.len == 0) continue;
        return std.mem.eql(u8, fstype, expected);
    }
    return false;
}

/// pid1 comm 是否为已知 init（宿主特征，仅作 hint 不计分）。
pub fn isKnownInit(comm: []const u8) bool {
    const known = [_][]const u8{ "systemd", "init", "upstart", "openrc", "runit", "s6-svscan" };
    for (&known) |k| {
        if (std.mem.eql(u8, comm, k)) return true;
    }
    return false;
}

/// pid1 environ 的 container= 值只允许 [A-Za-z0-9_-] 单词
/// （docker/podman/lxc/systemd-nspawn 等），含其他字符视为不可信：
/// hints 不收录（返回 null），INFO 行仍原样展示。
pub fn sanitizeHint(val: []const u8) ?[]const u8 {
    if (val.len == 0 or val.len > 32) return null;
    for (val) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return null;
    }
    return val;
}
