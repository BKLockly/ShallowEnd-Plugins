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
pub const max_output_matches: usize = 30;
pub const max_file_size: usize = 1024 * 1024;
pub const output_buf_size: usize = 2 * 1024 * 1024;
pub const content_scan_bytes: usize = 4096;

pub fn log(buf: []u8, offset: *usize, comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(buf[offset.*..], fmt, args) catch return;
    offset.* += result.len;
}
