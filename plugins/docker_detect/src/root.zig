const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());
}

pub fn detect(call: tokota.Call) ![]const u8 {
    _ = call;
    const builtin = @import("builtin");

    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    const write = struct {
        fn write(buffer: []u8, offset: *usize, comptime fmt: []const u8, args: anytype) void {
            const result = std.fmt.bufPrint(buffer[offset.*..], fmt, args) catch return;
            offset.* += result.len;
        }
    }.write;

    write(&buf, &len, "[DBUG] Platform: {s} {s}\n", .{ @tagName(builtin.os.tag), if (builtin.cpu.arch == .x86_64) "x64" else "arm64" });
    write(&buf, &len, "[DBUG] Running Docker detection...\n", .{});

    if (builtin.os.tag != .linux) {
        write(&buf, &len, "\n[WARN] /.dockerenv not found (non-Linux)\n", .{});
        write(&buf, &len, "[WARN] cgroup check skipped (non-Linux)\n", .{});
        write(&buf, &len, "[WARN] mountinfo check skipped (non-Linux)\n", .{});
        write(&buf, &len, "\n[INFO] Confidence: 0\n", .{});
        write(&buf, &len, "[WARN] Verdict: Not running in Docker container (host OS)\n", .{});

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
    } else {
        write(&buf, &len, "[WARN] /.dockerenv not found (+0)\n", .{});
    }

    const cgroupResult = checkCgroup();
    if (cgroupResult.found) {
        write(&buf, &len, "[INFO] cgroup contains \"{s}\" (+{})\n", .{ cgroupResult.pattern, cgroupResult.confidence });
        printFileMatches(&buf, &len, "/proc/1/cgroup", cgroupResult.pattern);
        confidence += cgroupResult.confidence;
    } else {
        write(&buf, &len, "[WARN] cgroup shows no container patterns (+0)\n", .{});
    }

    const mountResult = checkMountinfo();
    if (mountResult.found) {
        write(&buf, &len, "[INFO] mountinfo contains \"{s}\" (+{})\n", .{ mountResult.pattern, mountResult.confidence });
        printFileMatches(&buf, &len, "/proc/self/mountinfo", mountResult.pattern);
        confidence += mountResult.confidence;
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
        }
        confidence += envResult.confidence;
    } else {
        write(&buf, &len, "[WARN] No container env vars (+0)\n", .{});
    }

    write(&buf, &len, "\n[INFO] Confidence: {}\n", .{confidence});

    if (confidence >= 70) {
        write(&buf, &len, "[INFO] Verdict: Very likely running in Docker container\n", .{});
    } else if (confidence >= 40) {
        write(&buf, &len, "[INFO] Verdict: Possibly running in Docker container\n", .{});
    } else if (confidence >= 20) {
        write(&buf, &len, "[WARN] Verdict: Some Docker indicators present\n", .{});
    } else {
        write(&buf, &len, "[WARN] Verdict: Not running in Docker container\n", .{});
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

fn checkCgroup() struct { found: bool, pattern: []const u8, confidence: u8 } {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/1/cgroup", open_flags, 0) catch -1;
    if (fd < 0) return .{ .found = false, .pattern = "", .confidence = 0 };

    var buf: [4096]u8 = undefined;
    const content = std.posix.read(fd, &buf) catch 0;
    _ = std.c.close(fd);

    if (content == 0) return .{ .found = false, .pattern = "", .confidence = 0 };

    const data = buf[0..content];

    if (std.mem.indexOf(u8, data, "/docker/") != null) {
        return .{ .found = true, .pattern = "/docker/", .confidence = 35 };
    } else if (std.mem.indexOf(u8, data, "docker-") != null) {
        return .{ .found = true, .pattern = "docker-", .confidence = 35 };
    } else if (std.mem.indexOf(u8, data, "/lxc/") != null) {
        return .{ .found = true, .pattern = "/lxc/", .confidence = 20 };
    } else if (std.mem.indexOf(u8, data, "/kubepods") != null) {
        return .{ .found = true, .pattern = "/kubepods", .confidence = 25 };
    }

    return .{ .found = false, .pattern = "", .confidence = 0 };
}

fn checkMountinfo() struct { found: bool, pattern: []const u8, confidence: u8 } {
    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/mountinfo", open_flags, 0) catch -1;
    if (fd < 0) return .{ .found = false, .pattern = "", .confidence = 0 };

    var buf: [4096]u8 = undefined;
    const content = std.posix.read(fd, &buf) catch 0;
    _ = std.c.close(fd);

    if (content == 0) return .{ .found = false, .pattern = "", .confidence = 0 };

    const data = buf[0..content];

    if (std.mem.indexOf(u8, data, "docker") != null) {
        return .{ .found = true, .pattern = "docker", .confidence = 15 };
    } else if (std.mem.indexOf(u8, data, "overlay") != null) {
        return .{ .found = true, .pattern = "overlay", .confidence = 10 };
    }

    return .{ .found = false, .pattern = "", .confidence = 0 };
}

fn checkEnvVars() struct { foundCount: u8, confidence: u8, dockerContainer: bool, container: bool, kubernetes: bool } {
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
