const std = @import("std");

pub const FilePattern = struct {
    substr: []const u8,
    label: []const u8,
};

pub const filename_patterns = [_]FilePattern{
    .{ .substr = ".pem", .label = "certificate/key file" },
    .{ .substr = ".key", .label = "certificate/key file" },
    .{ .substr = ".crt", .label = "certificate file" },
    .{ .substr = ".env", .label = "environment variable file" },
    .{ .substr = ".pgpass", .label = "database password file" },
    .{ .substr = ".git-credentials", .label = "git credentials file" },
    .{ .substr = ".gitconfig", .label = "git configuration file" },
    .{ .substr = ".netrc", .label = "network credentials file" },
    .{ .substr = ".npmrc", .label = "npm configuration" },
    .{ .substr = ".dockercfg", .label = "Docker configuration" },
    .{ .substr = ".htpasswd", .label = "web authentication file" },
    .{ .substr = ".ovpn", .label = "VPN configuration file" },
    .{ .substr = "kubeconfig", .label = "Kubernetes configuration" },
    .{ .substr = ".my.cnf", .label = "MySQL configuration" },
    .{ .substr = "id_rsa", .label = "private key (RSA)" },
    .{ .substr = "id_ed25519", .label = "private key (Ed25519)" },
    .{ .substr = "id_ecdsa", .label = "private key (ECDSA)" },
    .{ .substr = "authorized_keys", .label = "SSH authorized keys" },
    .{ .substr = "known_hosts", .label = "SSH known hosts" },
    .{ .substr = "credential", .label = "credentials file" },
    .{ .substr = "secret", .label = "secrets file" },
    .{ .substr = "token", .label = "token file" },
    .{ .substr = ".db", .label = "database file" },
    .{ .substr = ".sqlite", .label = "SQLite database" },
    .{ .substr = "dump", .label = "data dump file" },
    .{ .substr = "backup", .label = "backup file" },
};

pub const content_patterns = [_]FilePattern{
    .{ .substr = "-----BEGIN", .label = "PEM-encoded data" },
    .{ .substr = "PRIVATE KEY", .label = "contains private key" },
    .{ .substr = "PASSWORD=", .label = "contains password variable" },
    .{ .substr = "password=", .label = "contains password variable" },
    .{ .substr = "password:", .label = "contains password variable" },
    .{ .substr = "password", .label = "contains password" },
    .{ .substr = "SECRET_KEY", .label = "contains secret key" },
    .{ .substr = "ACCESS_KEY", .label = "contains access key" },
    .{ .substr = "API_KEY", .label = "contains API key" },
    .{ .substr = "TOKEN=", .label = "contains token" },
    .{ .substr = "ssh-rsa AAAA", .label = "SSH public key" },
    .{ .substr = "ssh-ed25519 AAAA", .label = "SSH public key" },
    .{ .substr = "mysql://", .label = "database connection string" },
    .{ .substr = "postgres://", .label = "database connection string" },
    .{ .substr = "redis://", .label = "Redis connection string" },
    .{ .substr = "mongodb://", .label = "MongoDB connection string" },
};

pub const search_paths = [_][]const u8{"/"};

pub const max_depth: usize = 6;
pub const max_scanned: usize = 200000;
/// 全局最多回传的命中行数
pub const max_reported_matches: usize = 30;
pub const output_buf_size: usize = 2 * 1024 * 1024;
pub const content_scan_bytes: usize = 4096;

/// 按目录名跳过（basename 精确匹配，任意层级生效）
pub const skip_dir_names = [_][]const u8{
    "proc",     "sys",   "dev",  "run",         "boot",         "media",      "mnt",
    ".git",     ".svn",  ".hg",  "lost+found",  "$RECYCLE.BIN", "secfixes.d", "testdata",
    "fixtures", "mock",  "stub", "__pycache__", "node_modules", ".cache",     "vendor",
    ".tox",     ".eggs",
};

pub fn isSkipDir(name: []const u8) bool {
    for (&skip_dir_names) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// 全盘兜底扫描时按路径前缀跳过的系统目录树。
/// 这些树动辄数万到数十万文件（/usr/share 的文档/资源、/snap 的 squashfs、
/// /var/lib/docker 的容器 overlay、/var/cache 的包缓存）且几乎不含凭据，
/// 会把 max_scanned 预算在 readdir 到 /home 之前烧光。/usr 例外保留
/// /usr/local（手工部署应用的常见落点）。
const PathSkipRule = struct {
    prefix: []const u8,
    /// 前缀之下仍要扫描的子树
    exceptions: []const []const u8 = &.{},
};

pub const skip_path_rules = [_]PathSkipRule{
    .{ .prefix = "/usr", .exceptions = &.{"/usr/local"} },
    .{ .prefix = "/lib" }, // 含 /libexec；/lib32 /lib64 另列（非同一段）
    .{ .prefix = "/lib32" },
    .{ .prefix = "/lib64" },
    .{ .prefix = "/bin" },
    .{ .prefix = "/sbin" },
    .{ .prefix = "/snap" },
    .{ .prefix = "/var/cache" },
    .{ .prefix = "/var/lib/docker" },
    .{ .prefix = "/var/lib/containerd" },
};

/// path 是否位于 prefix 之内（按 path segment 精确匹配，"/libc" 不算 "/lib" 之下）
fn pathUnder(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// 目录是否位于应跳过的系统子树内。"/usr 需穿过、内部才跳"的场景靠
/// exceptions 放行通往例外的路径：/usr 放行、/usr/share 跳过、
/// /usr/local 及其内部放行。
pub fn isSkippedPath(path: []const u8) bool {
    for (&skip_path_rules) |rule| {
        if (!pathUnder(path, rule.prefix)) continue;
        for (rule.exceptions) |ex| {
            if (pathUnder(path, ex)) return false;
        }
        for (rule.exceptions) |ex| {
            // 仍在通往例外子树的路上（如 /usr 之于 /usr/local）
            if (pathUnder(ex, path)) return false;
        }
        return true;
    }
    return false;
}

/// 输出缓冲尾部保留量：预留给截断标记（约 60 字节）
pub const output_tail_reserve: usize = 128;

pub const truncation_marker = "[WARN] Output truncated: buffer full, some matches not shown\n";

/// 写入一行输出；缓冲触及尾部保留线或单行放不下时置位 truncated 并丢弃，
/// 保证缓冲尾部始终留有 writeTruncationMarker 的容身之处。
pub fn log(buf: []u8, offset: *usize, truncated: *bool, comptime fmt: []const u8, args: anytype) void {
    if (buf.len <= output_tail_reserve or offset.* > buf.len - output_tail_reserve) {
        truncated.* = true;
        return;
    }
    const result = std.fmt.bufPrint(buf[offset.* .. buf.len - output_tail_reserve], fmt, args) catch {
        truncated.* = true;
        return;
    };
    offset.* += result.len;
}

/// 收尾写入截断标记。绕过 log 的保留线（保留区本来就是留给它的）。
pub fn writeTruncationMarker(buf: []u8, offset: *usize) void {
    if (buf.len - offset.* <= truncation_marker.len) return;
    @memcpy(buf[offset.*..][0..truncation_marker.len], truncation_marker);
    offset.* += truncation_marker.len;
}
