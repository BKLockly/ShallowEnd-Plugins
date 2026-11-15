const std = @import("std");
const tokota = @import("tokota");
const logic = @import("detect_logic.zig");

comptime {
    tokota.exportModule(@This());
}

/// Runtime hints 聚合缓冲上限（名称去重拼接，远用不满）
const hints_buf_size = 128;

pub fn detect(call: tokota.Call) ![]const u8 {
    _ = call;
    const builtin = @import("builtin");

    // 16KB：多挂载 pod 的 mountinfo 匹配行可把 4KB 写满，
    // Confidence/Verdict 尾段会被静默挤掉（v3.1.0 的 4096 上限太小）
    var buf: [16384]u8 = undefined;
    var len: usize = 0;
    var hints_buf: [hints_buf_size]u8 = undefined;
    var hints_len: usize = 0;

    const write = struct {
        fn write(buffer: []u8, offset: *usize, comptime fmt: []const u8, args: anytype) void {
            const result = std.fmt.bufPrint(buffer[offset.*..], fmt, args) catch return;
            offset.* += result.len;
        }
    }.write;

    const addHint = struct {
        // 逐段查重（", " 分隔）后追加，重复的运行时名只记一次
        fn f(hints: []u8, hlen: *usize, name: []const u8) void {
            var it = std.mem.splitSequence(u8, hints[0..hlen.*], ", ");
            while (it.next()) |existing| {
                if (std.mem.eql(u8, existing, name)) return;
            }
            const prefix: []const u8 = if (hlen.* == 0) "" else ", ";
            const result = std.fmt.bufPrint(hints[hlen.*..], "{s}{s}", .{ prefix, name }) catch return;
            hlen.* += result.len;
        }
    }.f;

    write(&buf, &len, "[DEBU] Platform: {s} {s}\n", .{ @tagName(builtin.os.tag), if (builtin.cpu.arch == .x86_64) "x64" else "arm64" });
    write(&buf, &len, "[DEBU] Running container detection...\n", .{});

    if (builtin.os.tag != .linux) {
        write(&buf, &len, "\n[WARN] /.dockerenv not found (non-Linux)\n", .{});
        write(&buf, &len, "[WARN] cgroup check skipped (non-Linux)\n", .{});
        write(&buf, &len, "[WARN] mountinfo check skipped (non-Linux)\n", .{});
        write(&buf, &len, "\n[INFO] Confidence: 0\n", .{});
        write(&buf, &len, "[WARN] Verdict: Not running in a container (host OS)\n", .{});

        if (builtin.os.tag == .macos) {
            write(&buf, &len, "\n[WARN] Note: Docker containers run in a Linux VM on macOS\n", .{});
            if (checkFileExists("/var/run/docker.sock")) {
                write(&buf, &len, "[DEBU] Docker Desktop socket found at /var/run/docker.sock\n", .{});
            }
            if (checkFileExists("/Applications/Docker.app")) {
                write(&buf, &len, "[DEBU] Docker Desktop installed at /Applications/Docker.app\n", .{});
            }
        }

        const result = std.heap.c_allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(result, buf[0..len]);
        return result;
    }

    var confidence: u8 = 0;

    if (checkFileExists("/.dockerenv")) {
        write(&buf, &len, "[INFO] /.dockerenv exists (+40)\n", .{});
        confidence += 40;
        addHint(&hints_buf, &hints_len, "docker");
    } else {
        write(&buf, &len, "[WARN] /.dockerenv not found (+0)\n", .{});
    }

    if (checkFileExists("/run/.containerenv")) {
        write(&buf, &len, "[INFO] /run/.containerenv exists (+40, podman signature)\n", .{});
        confidence += 40;
        addHint(&hints_buf, &hints_len, "podman");
    } else {
        write(&buf, &len, "[WARN] /run/.containerenv not found (+0)\n", .{});
    }

    const cgroupResult = checkCgroup();
    if (cgroupResult.found) {
        write(&buf, &len, "[INFO] cgroup contains \"{s}\" (+{})\n", .{ cgroupResult.pattern, cgroupResult.confidence });
        printFileMatches(&buf, &len, "/proc/1/cgroup", cgroupResult.pattern);
        confidence += cgroupResult.confidence;
        if (cgroupResult.hint.len > 0) addHint(&hints_buf, &hints_len, cgroupResult.hint);
    } else {
        write(&buf, &len, "[WARN] cgroup shows no container patterns (+0)\n", .{});
    }

    const mountResult = checkMountinfo();
    if (mountResult.confidence > 0) {
        if (mountResult.docker_found) {
            write(&buf, &len, "[INFO] mountinfo contains \"docker\" (+15)\n", .{});
            printFileMatches(&buf, &len, "/proc/self/mountinfo", "docker");
            addHint(&hints_buf, &hints_len, "docker");
        }
        if (mountResult.root_overlay) {
            write(&buf, &len, "[INFO] mountinfo root mount fstype=overlay (+25)\n", .{});
        }
        if (mountResult.overlay_generic and !mountResult.root_overlay) {
            write(&buf, &len, "[INFO] mountinfo contains \"overlay\" (+10)\n", .{});
            printFileMatches(&buf, &len, "/proc/self/mountinfo", "overlay");
        }
        confidence += mountResult.confidence;
    } else {
        write(&buf, &len, "[WARN] mountinfo shows no container patterns (+0)\n", .{});
    }

    // 环境变量 + pid1 environ。container= 只计一次分：pid1 environ 的
    // container=（systemd-detect-virt 同款判据）为权威信号 +25；
    // pid1 读不到（如非 root 宿主 EACCES）时回退当前进程 env +10。
    const envResult = checkEnvVars();
    if (envResult.dockerContainer) {
        write(&buf, &len, "[INFO] DOCKER_CONTAINER env var set (+10)\n", .{});
        if (std.c.getenv("DOCKER_CONTAINER")) |val| {
            write(&buf, &len, "[DEBU]   DOCKER_CONTAINER={s}\n", .{val});
        }
        addHint(&hints_buf, &hints_len, "docker");
    }
    if (envResult.kubernetes) {
        write(&buf, &len, "[INFO] KUBERNETES_SERVICE_HOST set (+15)\n", .{});
        if (std.c.getenv("KUBERNETES_SERVICE_HOST")) |val| {
            write(&buf, &len, "[DEBU]   KUBERNETES_SERVICE_HOST={s}\n", .{val});
        }
        addHint(&hints_buf, &hints_len, "kubernetes");
    }
    if (envResult.dockerContainer or envResult.kubernetes) {
        confidence += envResult.confidence;
    } else if (!envResult.container) {
        write(&buf, &len, "[WARN] No container env vars (+0)\n", .{});
    }
    if (envResult.container) {
        if (std.c.getenv("container")) |val| {
            write(&buf, &len, "[DEBU]   container={s}\n", .{val});
        }
    }

    var pid1_env_buf: [64]u8 = undefined;
    if (readPid1EnvContainer(&pid1_env_buf)) |cval| {
        write(&buf, &len, "[INFO] pid1 environ container={s} (+25)\n", .{cval});
        confidence += 25;
        if (logic.sanitizeHint(cval)) |h| addHint(&hints_buf, &hints_len, h);
    } else if (envResult.container) {
        write(&buf, &len, "[INFO] container env var set (+10)\n", .{});
        confidence += 10;
    }

    // pid1 检查：仅作 hint 不计分（宿主裸跑 supervisor/runit 时会误报）
    var pid1_buf: [64]u8 = undefined;
    if (readPid1Comm(&pid1_buf)) |comm| {
        if (logic.isKnownInit(comm)) {
            write(&buf, &len, "[DEBU] pid1: {s} (known init — host-like, not scored)\n", .{comm});
        } else {
            write(&buf, &len, "[INFO] pid1: {s} (not a known init — weak container hint, not scored)\n", .{comm});
        }
    } else {
        write(&buf, &len, "[DEBU] pid1 comm unavailable\n", .{});
    }

    write(&buf, &len, "\n[INFO] Confidence: {}\n", .{confidence});
    if (hints_len > 0) {
        write(&buf, &len, "[INFO] Runtime hints: {s}\n", .{hints_buf[0..hints_len]});
    } else {
        write(&buf, &len, "[INFO] Runtime hints: none\n", .{});
    }

    if (confidence >= 70) {
        write(&buf, &len, "[INFO] Verdict: Very likely running in a container\n", .{});
    } else if (confidence >= 40) {
        write(&buf, &len, "[INFO] Verdict: Possibly running in a container\n", .{});
    } else if (confidence >= 20) {
        write(&buf, &len, "[WARN] Verdict: Some container indicators present\n", .{});
    } else {
        write(&buf, &len, "[WARN] Verdict: Not running in a container\n", .{});
    }

    const result = std.heap.c_allocator.alloc(u8, len) catch return error.OutOfMemory;
    @memcpy(result, buf[0..len]);
    return result;
}

fn checkFileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch -1;
    if (fd >= 0) {
        _ = std.c.close(fd);
        return true;
    }
    return false;
}

/// 读 /proc/1/comm（pid1 进程名，不含换行）
fn readPid1Comm(buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/1/comm", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.c.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    if (n == 0) return null;
    var comm = buf[0..n];
    if (std.mem.indexOfScalar(u8, comm, '\n')) |i| comm = comm[0..i];
    if (comm.len == 0) return null;
    return comm;
}

/// 展示命中 pattern 的行；最多展示 8 行 + 截断提示（多挂载 pod 几十条
/// 命中行会挤爆输出缓冲，verdict 是唯一结论行必须保住）。
fn printFileMatches(buf: []u8, offset: *usize, filepath: []const u8, pattern: []const u8) void {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, filepath, open_flags, 0) catch return;
    defer _ = std.c.close(fd);

    var file_buf: [4096]u8 = undefined;
    const content = std.posix.read(fd, &file_buf) catch return;
    if (content == 0) return;

    const data = file_buf[0..content];
    var line_start: usize = 0;
    var shown: usize = 0;
    var hidden: usize = 0;
    while (line_start < data.len) {
        const line_end = if (std.mem.indexOfScalar(u8, data[line_start..], '\n')) |idx| line_start + idx else data.len;
        const line = data[line_start..line_end];
        if (line.len > 0 and std.mem.indexOf(u8, line, pattern) != null) {
            if (shown < 8) {
                const result = std.fmt.bufPrint(buf[offset.*..], "[DEBU]   {s}\n", .{line}) catch return;
                offset.* += result.len;
                shown += 1;
            } else {
                hidden += 1;
            }
        }
        line_start = line_end + 1;
    }
    if (hidden > 0) {
        const result = std.fmt.bufPrint(buf[offset.*..], "[DEBU]   ... ({d} more matching lines hidden)\n", .{hidden}) catch return;
        offset.* += result.len;
    }
}

const CgroupResult = logic.CgroupResult;
const MountResult = logic.MountResult;

fn checkCgroup() CgroupResult {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/1/cgroup", open_flags, 0) catch
        return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };

    var buf: [4096]u8 = undefined;
    const content = std.posix.read(fd, &buf) catch 0;
    _ = std.c.close(fd);

    if (content == 0) return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };
    return logic.analyzeCgroup(buf[0..content]);
}

fn checkMountinfo() MountResult {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/mountinfo", open_flags, 0) catch
        return .{ .docker_found = false, .root_overlay = false, .overlay_generic = false, .confidence = 0 };

    // 大挂载表（几百条目）可超 4KB，循环读满 64KB 上限
    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = std.c.close(fd);

    if (total == 0) return .{ .docker_found = false, .root_overlay = false, .overlay_generic = false, .confidence = 0 };
    return logic.analyzeMountinfo(buf[0..total]);
}

/// 读 /proc/1/environ（NUL 分隔的 key=value），取 container= 的值。
/// 读不到时返回 null：payload 用户 ≠ pid1 用户（非 root 宿主）会 EACCES，
/// 此时优雅降级为无此信号（当前进程 env 的 container= 回退 +10）。
fn readPid1EnvContainer(buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/1/environ", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.c.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry, "container=")) {
            const val = entry["container=".len..];
            if (val.len == 0) return null;
            return val;
        }
    }
    return null;
}

const EnvResult = struct {
    confidence: u8,
    dockerContainer: bool,
    container: bool,
    kubernetes: bool,
};

/// container= 环境变量只做标记不计分——计分统一由 pid1 environ（+25）
/// 或其不可读时的回退路径（+10）处理，避免同一信号双重计分。
fn checkEnvVars() EnvResult {
    var confidence: u8 = 0;
    var dockerContainer: bool = false;
    var container: bool = false;
    var kubernetes: bool = false;

    if (std.c.getenv("DOCKER_CONTAINER")) |_| {
        dockerContainer = true;
        confidence += 10;
    }

    if (std.c.getenv("container")) |_| {
        container = true;
    }

    if (std.c.getenv("KUBERNETES_SERVICE_HOST")) |_| {
        kubernetes = true;
        confidence += 15;
    }

    return .{ .confidence = confidence, .dockerContainer = dockerContainer, .container = container, .kubernetes = kubernetes };
}
