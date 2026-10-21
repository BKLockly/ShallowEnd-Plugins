const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());
}

/// Runtime hints 聚合缓冲上限（名称去重拼接，远用不满）
const hints_buf_size = 128;

pub fn detect(call: tokota.Call) ![]const u8 {
    _ = call;
    const builtin = @import("builtin");

    var buf: [4096]u8 = undefined;
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

    write(&buf, &len, "[DBUG] Platform: {s} {s}\n", .{ @tagName(builtin.os.tag), if (builtin.cpu.arch == .x86_64) "x64" else "arm64" });
    write(&buf, &len, "[DBUG] Running container detection...\n", .{});

    if (builtin.os.tag != .linux) {
        write(&buf, &len, "\n[WARN] /.dockerenv not found (non-Linux)\n", .{});
        write(&buf, &len, "[WARN] cgroup check skipped (non-Linux)\n", .{});
        write(&buf, &len, "[WARN] mountinfo check skipped (non-Linux)\n", .{});
        write(&buf, &len, "\n[INFO] Confidence: 0\n", .{});
        write(&buf, &len, "[WARN] Verdict: Not running in a container (host OS)\n", .{});

        if (builtin.os.tag == .macos) {
            write(&buf, &len, "\n[WARN] Note: Docker containers run in a Linux VM on macOS\n", .{});
            if (checkFileExists("/var/run/docker.sock")) {
                write(&buf, &len, "[DBUG] Docker Desktop socket found at /var/run/docker.sock\n", .{});
            }
            if (checkFileExists("/Applications/Docker.app")) {
                write(&buf, &len, "[DBUG] Docker Desktop installed at /Applications/Docker.app\n", .{});
            }
        }

        const result = std.heap.c_allocator.alloc(u8, len) catch unreachable;
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
        addHint(&hints_buf, &hints_len, cgroupResult.hint);
    } else {
        write(&buf, &len, "[WARN] cgroup shows no container patterns (+0)\n", .{});
    }

    const mountResult = checkMountinfo();
    if (mountResult.found) {
        write(&buf, &len, "[INFO] mountinfo contains \"{s}\" (+{})\n", .{ mountResult.pattern, mountResult.confidence });
        printFileMatches(&buf, &len, "/proc/self/mountinfo", mountResult.pattern);
        confidence += mountResult.confidence;
        if (mountResult.hint.len > 0) addHint(&hints_buf, &hints_len, mountResult.hint);
    } else {
        write(&buf, &len, "[WARN] mountinfo shows no container patterns (+0)\n", .{});
    }

    const envResult = checkEnvVars();
    if (envResult.foundCount > 0) {
        if (envResult.dockerContainer) {
            write(&buf, &len, "[INFO] DOCKER_CONTAINER env var set (+10)\n", .{});
            if (std.c.getenv("DOCKER_CONTAINER")) |val| {
                write(&buf, &len, "[DBUG]   DOCKER_CONTAINER={s}\n", .{val});
            }
            addHint(&hints_buf, &hints_len, "docker");
        }
        if (envResult.container) {
            write(&buf, &len, "[INFO] container env var set (+10)\n", .{});
            if (std.c.getenv("container")) |val| {
                write(&buf, &len, "[DBUG]   container={s}\n", .{val});
            }
        }
        if (envResult.kubernetes) {
            write(&buf, &len, "[INFO] KUBERNETES_SERVICE_HOST set (+15)\n", .{});
            if (std.c.getenv("KUBERNETES_SERVICE_HOST")) |val| {
                write(&buf, &len, "[DBUG]   KUBERNETES_SERVICE_HOST={s}\n", .{val});
            }
            addHint(&hints_buf, &hints_len, "kubernetes");
        }
        confidence += envResult.confidence;
    } else {
        write(&buf, &len, "[WARN] No container env vars (+0)\n", .{});
    }

    // pid1 检查：仅作 hint 不计分（宿主裸跑 supervisor/runit 时会误报）
    var pid1_buf: [64]u8 = undefined;
    if (readPid1Comm(&pid1_buf)) |comm| {
        if (isKnownInit(comm)) {
            write(&buf, &len, "[DBUG] pid1: {s} (known init — host-like, not scored)\n", .{comm});
        } else {
            write(&buf, &len, "[INFO] pid1: {s} (not a known init — weak container hint, not scored)\n", .{comm});
        }
    } else {
        write(&buf, &len, "[DBUG] pid1 comm unavailable\n", .{});
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

    const result = std.heap.c_allocator.alloc(u8, len) catch unreachable;
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

fn isKnownInit(comm: []const u8) bool {
    const known = [_][]const u8{ "systemd", "init", "upstart", "openrc", "runit", "s6-svscan" };
    for (&known) |k| {
        if (std.mem.eql(u8, comm, k)) return true;
    }
    return false;
}

fn printFileMatches(buf: []u8, offset: *usize, filepath: []const u8, pattern: []const u8) void {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, filepath, open_flags, 0) catch return;
    defer _ = std.c.close(fd);

    var file_buf: [4096]u8 = undefined;
    const content = std.posix.read(fd, &file_buf) catch return;
    if (content == 0) return;

    const data = file_buf[0..content];
    var line_start: usize = 0;
    while (line_start < data.len) {
        const line_end = if (std.mem.indexOfScalar(u8, data[line_start..], '\n')) |idx| line_start + idx else data.len;
        const line = data[line_start..line_end];
        if (line.len > 0 and std.mem.indexOf(u8, line, pattern) != null) {
            const result = std.fmt.bufPrint(buf[offset.*..], "[DBUG]   {s}\n", .{line}) catch return;
            offset.* += result.len;
        }
        line_start = line_end + 1;
    }
}

const CgroupResult = struct {
    found: bool,
    pattern: []const u8,
    confidence: u8,
    hint: []const u8,
};

fn checkCgroup() CgroupResult {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/1/cgroup", open_flags, 0) catch -1;
    if (fd < 0) return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };

    var buf: [4096]u8 = undefined;
    const content = std.posix.read(fd, &buf) catch 0;
    _ = std.c.close(fd);

    if (content == 0) return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };

    const data = buf[0..content];

    if (std.mem.indexOf(u8, data, "/docker/") != null) {
        return .{ .found = true, .pattern = "/docker/", .confidence = 35, .hint = "docker" };
    } else if (std.mem.indexOf(u8, data, "docker-") != null) {
        return .{ .found = true, .pattern = "docker-", .confidence = 35, .hint = "docker" };
    } else if (std.mem.indexOf(u8, data, "/lxc/") != null) {
        return .{ .found = true, .pattern = "/lxc/", .confidence = 20, .hint = "lxc" };
    } else if (std.mem.indexOf(u8, data, "/kubepods") != null) {
        return .{ .found = true, .pattern = "/kubepods", .confidence = 25, .hint = "kubernetes" };
    }

    return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };
}

const MountResult = struct {
    found: bool,
    pattern: []const u8,
    confidence: u8,
    hint: []const u8,
};

fn checkMountinfo() MountResult {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/mountinfo", open_flags, 0) catch -1;
    if (fd < 0) return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };

    // 大挂载表（几百条目）可超 4KB，循环读满 64KB 上限
    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = std.c.close(fd);

    if (total == 0) return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };

    const data = buf[0..total];

    if (std.mem.indexOf(u8, data, "docker") != null) {
        return .{ .found = true, .pattern = "docker", .confidence = 15, .hint = "docker" };
    } else if (std.mem.indexOf(u8, data, "overlay") != null) {
        return .{ .found = true, .pattern = "overlay", .confidence = 10, .hint = "" };
    }

    return .{ .found = false, .pattern = "", .confidence = 0, .hint = "" };
}

const EnvResult = struct {
    foundCount: u8,
    confidence: u8,
    dockerContainer: bool,
    container: bool,
    kubernetes: bool,
};

fn checkEnvVars() EnvResult {
    var foundCount: u8 = 0;
    var confidence: u8 = 0;
    var dockerContainer: bool = false;
    var container: bool = false;
    var kubernetes: bool = false;

    if (std.c.getenv("DOCKER_CONTAINER")) |_| {
        dockerContainer = true;
        confidence += 10;
        foundCount += 1;
    }

    if (std.c.getenv("container")) |_| {
        container = true;
        confidence += 10;
        foundCount += 1;
    }

    if (std.c.getenv("KUBERNETES_SERVICE_HOST")) |_| {
        kubernetes = true;
        confidence += 15;
        foundCount += 1;
    }

    return .{ .foundCount = foundCount, .confidence = confidence, .dockerContainer = dockerContainer, .container = container, .kubernetes = kubernetes };
}
