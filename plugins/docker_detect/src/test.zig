const std = @import("std");
const logic = @import("detect_logic.zig");

test "analyzeCgroup scores v1 patterns" {
    const r1 = logic.analyzeCgroup("12:cpuset:/docker/abc123\n");
    try std.testing.expect(r1.found);
    try std.testing.expectEqual(@as(u8, 35), r1.confidence);
    try std.testing.expectEqualStrings("docker", r1.hint);

    const r2 = logic.analyzeCgroup("12:devices:/kubepods/besteffort/podxyz\n");
    try std.testing.expect(r2.found);
    try std.testing.expectEqual(@as(u8, 25), r2.confidence);
    try std.testing.expectEqualStrings("kubernetes", r2.hint);

    const r3 = logic.analyzeCgroup("12:cpuset:/lxc/1234\n");
    try std.testing.expect(r3.found);
    try std.testing.expectEqual(@as(u8, 20), r3.confidence);
}

test "analyzeCgroup v2 unified 0::/ gives weak score (v3.2.0 regression)" {
    // Docker 19+ / K8s cgroup v2 容器内 /proc/1/cgroup 就这一行，
    // v3.1.0 在此全部落空；宿主 systemd 是 0::/init.scope 不会误中
    const r = logic.analyzeCgroup("0::/\n");
    try std.testing.expect(r.found);
    try std.testing.expectEqual(@as(u8, 10), r.confidence);
    try std.testing.expectEqual(@as(usize, 0), r.hint.len);

    // 宿主 systemd 的 pid1 行不触发弱分
    const host = logic.analyzeCgroup("0::/init.scope\n");
    try std.testing.expect(!host.found);

    // 传统 v1 混合行（无容器特征）也不触发
    const v1host = logic.analyzeCgroup("12:cpuset:/\n");
    try std.testing.expect(!v1host.found);
}

test "rootMountFstypeEql finds root mount and compares fstype" {
    // Docker 容器典型 mountinfo：根挂载 overlay
    const docker_root = "712 705 0:36 / / rw,relatime - overlay overlay rw,upperdir=/x,lowerdir=/y\n" ++
        "740 712 0:40 /proc /proc rw,nosuid - proc proc rw\n";
    try std.testing.expect(logic.rootMountFstypeEql(docker_root, "overlay"));
    try std.testing.expect(!logic.rootMountFstypeEql(docker_root, "ext4"));

    // 宿主典型：根挂载 ext4，overlay 出现在其他行（如 docker 存储目录）
    const host = "22 1 0:21 / / rw,relatime - ext4 /dev/sda1 rw\n" ++
        "99 22 0:36 /var/lib/docker /var/lib/docker rw - overlay overlay rw\n";
    try std.testing.expect(!logic.rootMountFstypeEql(host, "overlay"));

    // 根挂载行不保证首行（契约无序），仍须命中
    const reordered = "740 712 0:40 /proc /proc rw,nosuid - proc proc rw\n" ++
        "712 705 0:36 / / rw,relatime - overlay overlay rw\n";
    try std.testing.expect(logic.rootMountFstypeEql(reordered, "overlay"));
}

test "analyzeMountinfo root overlay outweighs generic substring (v3.2.0 regression)" {
    // 容器：docker 字样 + 根 overlay → 15 + 25
    const in_container = "712 705 0:36 / / rw,relatime - overlay overlay rw\n" ++
        "750 712 0:41 /docker/entrypoint /entrypoint rw - overlay overlay rw\n";
    const r = logic.analyzeMountinfo(in_container);
    try std.testing.expect(r.docker_found);
    try std.testing.expect(r.root_overlay);
    try std.testing.expect(!r.overlay_generic);
    try std.testing.expectEqual(@as(u8, 40), r.confidence);

    // 宿主（跑着 docker）：根 ext4，docker 存储目录挂 overlay → 既有语义 docker 字样 +15 + 泛化 overlay +10
    const on_host = "22 1 0:21 / / rw,relatime - ext4 /dev/sda1 rw\n" ++
        "99 22 0:36 /var/lib/docker /var/lib/docker rw - overlay overlay rw\n";
    const h = logic.analyzeMountinfo(on_host);
    try std.testing.expect(!h.root_overlay);
    try std.testing.expect(h.docker_found);
    try std.testing.expect(h.overlay_generic);
    try std.testing.expectEqual(@as(u8, 25), h.confidence);

    // 宿主（无 docker）：根 ext4，仅某目录挂 overlay → 仅泛化 +10
    const on_host_nodocker = "22 1 0:21 / / rw,relatime - ext4 /dev/sda1 rw\n" ++
        "99 22 0:36 /srv/lower /srv/lower rw - overlay overlay rw\n";
    const h2 = logic.analyzeMountinfo(on_host_nodocker);
    try std.testing.expect(!h2.root_overlay);
    try std.testing.expect(!h2.docker_found);
    try std.testing.expect(h2.overlay_generic);
    try std.testing.expectEqual(@as(u8, 10), h2.confidence);
}

test "isKnownInit and sanitizeHint" {
    try std.testing.expect(logic.isKnownInit("systemd"));
    try std.testing.expect(!logic.isKnownInit("bash"));

    try std.testing.expectEqualStrings("docker", logic.sanitizeHint("docker").?);
    try std.testing.expectEqualStrings("systemd-nspawn", logic.sanitizeHint("systemd-nspawn").?);
    try std.testing.expect(logic.sanitizeHint("") == null);
    try std.testing.expect(logic.sanitizeHint("dock er") == null);
    try std.testing.expect(logic.sanitizeHint("../etc") == null);
    // 超长值不收进 hints
    const long_val = "a" ** 33;
    try std.testing.expect(logic.sanitizeHint(long_val) == null);
}
