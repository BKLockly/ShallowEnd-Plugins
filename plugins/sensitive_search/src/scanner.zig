const std = @import("std");
const types = @import("types.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("scanner.zig is Linux-only");
    }
}

const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;
const DT_LNK: u8 = 10;

const skip_extensions = [_][]const u8{
    ".o", ".so", ".dll", ".dylib", ".a", ".lib",
    ".pyc", ".pyo", ".class", ".jar", ".war",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp",
    ".mp3", ".mp4", ".avi", ".mov", ".mkv", ".wav", ".flac", ".webm",
    ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar", ".zst",
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".exe", ".msi", ".deb", ".rpm", ".apk", ".ipa",
    ".bin", ".dat", ".img", ".iso", ".vmdk", ".qcow2",
    ".node", ".ttf", ".otf", ".woff", ".woff2", ".eot",
    ".psd", ".ai", ".eps", ".sketch", ".fig",
    ".swp", ".swo",
};

const text_extensions = [_][]const u8{
    ".txt", ".md", ".rst", ".adoc",
    ".json", ".xml", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".properties",
    ".env", ".envrc",
    ".sh", ".bash", ".zsh", ".fish",
    ".py", ".rb", ".pl", ".pm", ".tcl",
    ".js", ".ts", ".jsx", ".tsx", ".vue",
    ".go", ".rs", ".zig", ".java", ".kt", ".scala",
    ".c", ".h", ".cpp", ".hpp", ".cc", ".hh", ".cxx", ".hxx",
    ".cs", ".fs", ".fsx",
    ".php", ".phtml",
    ".swift",
    ".sql", ".psql",
    ".lua",
    ".r", ".R",
    ".groovy", ".gradle",
    ".dockerfile", ".Dockerfile",
    ".htm", ".html", ".css", ".scss", ".less", ".sass",
    ".makefile", ".gnumakefile",
    ".cmake",
    ".terraform", ".tf", ".tfvars",
};

const skip_dir_names = [_][]const u8{
    "proc", "sys", "dev", "run", "boot", "media", "mnt",
    ".git", ".svn", ".hg",
    "lost+found",
    "$RECYCLE.BIN",
    "secfixes.d", "testdata", "fixtures", "mock", "stub",
    "__pycache__", "node_modules", ".cache",
    "vendor", ".tox", ".eggs",
};

fn tryOpenDir(dir_fd: std.posix.fd_t, name: []const u8) bool {
    const fd = std.posix.openat(dir_fd, name, .{ .DIRECTORY = true, .ACCMODE = .RDONLY }, 0);
    if (fd) |f| {
        _ = std.c.close(f);
        return true;
    } else |_| return false;
}

fn isTextExtension(name: []const u8) bool {
    for (&text_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn matchContentBytes(data: []const u8) ?[]const u8 {
    for (&types.content_patterns) |p| {
        if (std.mem.indexOf(u8, data, p.substr) != null) {
            return p.label;
        }
    }
    return null;
}

fn matchFile(dir_fd: std.posix.fd_t, entry_name: []const u8, search_content: bool) ?[]const u8 {
    for (&types.filename_patterns) |p| {
        if (std.mem.indexOf(u8, entry_name, p.substr) != null) {
            return p.label;
        }
    }

    if (!search_content) return null;
    if (!isTextExtension(entry_name)) return null;

    const open_flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    const fd = std.posix.openat(dir_fd, entry_name, open_flags, 0) catch return null;
    defer _ = std.c.close(fd);

    var buf: [types.content_scan_bytes]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return null;
    if (n == 0) return null;

    for (buf[0..n]) |byte| {
        if (byte == 0) return null;
    }

    return matchContentBytes(buf[0..n]);
}

fn walkDir(
    parent_fd: std.posix.fd_t,
    current_path: []const u8,
    current_depth: usize,
    buf: []u8,
    len: *usize,
    total_scanned: *usize,
    matches_found: *usize,
    errors_count: *usize,
    search_content: bool,
) void {
    if (current_depth > types.max_depth) return;

    const dir_fd = std.posix.openat(parent_fd, ".", .{ .DIRECTORY = true, .ACCMODE = .RDONLY }, 0) catch {
        errors_count.* += 1;
        return;
    };
    defer _ = std.c.close(dir_fd);

    const dir_stream = std.c.fdopendir(dir_fd) orelse {
        errors_count.* += 1;
        return;
    };
    defer _ = std.c.closedir(dir_stream);

    if (total_scanned.* >= types.max_scanned) return;

    var reported: usize = 0;

    while (true) {
        const entry = std.c.readdir(dir_stream) orelse break;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        if (entry.type == DT_LNK) continue;

        const is_dir = switch (entry.type) {
            DT_DIR => true,
            DT_REG => false,
            else => if (isSkipDir(name)) false else tryOpenDir(dir_fd, name),
        };

        if (is_dir) {
            if (isSkipDir(name)) continue;
            const child_fd = std.posix.openat(parent_fd, name, .{ .DIRECTORY = true, .ACCMODE = .RDONLY }, 0) catch {
                errors_count.* += 1;
                continue;
            };
            defer _ = std.c.close(child_fd);
            var path_buf: [4096]u8 = undefined;
            const fp = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ current_path, name }) catch continue;
            walkDir(child_fd, fp, current_depth + 1, buf, len, total_scanned, matches_found, errors_count, search_content);
            continue;
        }

        total_scanned.* += 1;
        if (matchFile(dir_fd, name, search_content)) |label| {
            matches_found.* += 1;
            if (reported < types.max_output_matches) {
                var path_buf: [4096]u8 = undefined;
                const fp = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ current_path, name }) catch continue;
                types.log(buf, len, "[WARN] Found: {s} ({s})\n", .{ fp, label });
                reported += 1;
            }
        }
    }

}

fn isSkipDir(name: []const u8) bool {
    for (&skip_dir_names) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

pub fn scan(base_path: []const u8, buf: []u8, len: *usize, total_scanned: *usize, matches_found: *usize, errors_count: *usize, search_content: bool) bool {
    const base_fd = std.posix.openat(std.posix.AT.FDCWD, base_path, .{ .DIRECTORY = true, .ACCMODE = .RDONLY }, 0) catch {
        types.log(buf, len, "[ERRO] Permission denied: {s}/\n", .{base_path});
        errors_count.* += 1;
        return false;
    };
    defer _ = std.c.close(base_fd);

    types.log(buf, len, "[DBUG] Scanning {s}/\n", .{base_path});

    walkDir(base_fd, "", 0, buf, len, total_scanned, matches_found, errors_count, search_content);

    return true;
}
