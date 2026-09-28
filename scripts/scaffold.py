#!/usr/bin/env python3
"""
插件脚手架 — 在 plugins/ 下生成一个新的 Node addon 插件项目。

用法:
    python3 scripts/scaffold.py <插件名>
    python3 scripts/scaffold.py <插件名> --label "显示名称" --desc "描述" --risk low

示例:
    python3 scripts/scaffold.py port_scan --label "端口扫描" --desc "TCP 端口扫描"
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGINS_DIR = os.path.join(ROOT, "plugins")

BUILD_ZIG = '''const std = @import("std");
const tokota = @import("tokota");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.dependency("tokota", .{
        .target = target,
        .optimize = optimize,
    });

    const addon = tokota.Addon.create(b, .{
        .name = "@@ADDON@@",
        .mode = optimize,
        .target = target,
        .root_source_file = b.path("src/root.zig"),
        .output_dir = .{ .custom = "../" },
        .link_libc = true,
    });

    b.getInstallStep().dependOn(&addon.install.step);

    // 单元测试 - 独立文件，不依赖 tokota（CI 中无 Node 运行时）
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
'''

BUILD_ZON = '''.{
    .name = .@@ZIGMOD@@,
    .version = "0.1.0",
    .fingerprint = 0x@@FINGERPRINT@@,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .tokota = .{
            .url = "https://github.com/kofi-q/tokota/archive/f8b15cf72d649229f317b9e588bb4a1622188da8.tar.gz",
            .hash = "tokota-0.1.0-BE_-yofCCQAWt55xe2uD9yg3QuNzdXaN67bDNgdBbwL5",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
'''

ROOT_ZIG = '''const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());
}

/// 示例方法：返回问候字符串。所有方法统一接收一个 JS 对象参数。
/// 字符串参数需用 Val.stringAlloc 显式转换（tokota 不支持 getT(_, []const u8)）。
pub fn @@ADDON@@(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);

    var name: []const u8 = "world";
    if (params.get("name")) |val| {
        if (!try val.isNullOrUndefined(call.env)) {
            name = try val.stringAlloc(call.env, std.heap.c_allocator);
        }
    } else |_| {}

    return std.fmt.allocPrint(std.heap.c_allocator, "[INFO] hello, {s}!", .{name});
}
'''

TEST_ZIG = '''const std = @import("std");
const testing = std.testing;

// 独立单元测试：不 import tokota（无 Node 运行时也可运行）。
// 测试纯逻辑工具函数；需要 Node 的集成测试放到 test.js。
test "example: arithmetic" {
    try testing.expectEqual(@as(u8, 2), 1 + 1);
}
'''

TEST_JS = '''// 集成冒烟测试：需要先 zig build（宿主平台产物）
const addon = require("./@@ADDON@@.node");
console.log(addon.@@ADDON@@({ name: "scaffold" }));
'''

MAKEFILE = '''NAME  := @@NAME@@
ADDON := @@ADDON@@.node

.PHONY: build-all test node-test clean

build-all:
\tmkdir -p dist
\tzig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall && mv $(ADDON) dist/$(NAME)-linux-x64.node
\tzig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall && mv $(ADDON) dist/$(NAME)-linux-arm64.node

test:
\tzig build test

node-test:
\tnode test.js

clean:
\trm -rf dist .zig-cache $(ADDON)
'''

PLUGIN_JSON = {
    "name": "@@NAME@@",
    "label": "@@LABEL@@",
    "description": "@@DESC@@",
    "version": "0.1.0",
    "author": "@@AUTHOR@@",
    "risk_level": "@@RISK@@",
    "methods": [
        {
            "name": "@@ADDON@@",
            "label": "@@LABEL@@",
            "description": "@@DESC@@",
            "params": [
                {"name": "name", "type": "text", "label": "名称", "required": False}
            ],
        }
    ],
}


def to_snake(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def autofix_fingerprint(plugin_dir: str) -> None:
    """Zig 0.16 按包名校验 fingerprint（随机值会被拒）。

    先用占位值跑一次 `zig build test`，从报错中取出 zig 建议的
    fingerprint 回填 zon，再验证一次。
    """
    zon_path = os.path.join(plugin_dir, "build.zig.zon")
    try:
        proc = subprocess.run(
            ["zig", "build", "test"],
            cwd=plugin_dir,
            capture_output=True,
            text=True,
            timeout=300,
        )
    except FileNotFoundError:
        print("  note: zig not in PATH — 请手动跑一次 `zig build test`，"
              "把报错中 'use this value:' 的 fingerprint 填进 build.zig.zon")
        return

    match = re.search(r"use this value: (0x[0-9a-fA-F]+)", proc.stderr + proc.stdout)
    if not match:
        return  # 构建因其他原因失败，交给开发者处理

    suggested = match.group(1)
    with open(zon_path) as f:
        zon = f.read()
    zon = re.sub(r"\.fingerprint = 0x[0-9a-fA-F]+,", f".fingerprint = {suggested},", zon)
    with open(zon_path, "w") as f:
        f.write(zon)
    print(f"  fingerprint autofixed -> {suggested}")

    check = subprocess.run(
        ["zig", "build", "test"],
        cwd=plugin_dir,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if check.returncode == 0:
        print("  zig build test PASS")
    else:
        print("  WARNING: zig build test 仍未通过，请检查生成的模板文件")


def main():
    parser = argparse.ArgumentParser(description="Scaffold a new ShallowEnd plugin")
    parser.add_argument("name", help="Plugin name, snake_case (e.g. port_scan)")
    parser.add_argument("--label", default=None, help="Display label")
    parser.add_argument("--desc", default="", help="Description")
    parser.add_argument("--author", default="BKLockly", help="Author")
    parser.add_argument("--risk", default="low", choices=["low", "medium", "high"], help="Risk level")
    args = parser.parse_args()

    name = to_snake(args.name)
    if not name:
        sys.exit("ERROR: invalid plugin name")
    plugin_dir = os.path.join(PLUGINS_DIR, name)
    if os.path.exists(plugin_dir):
        sys.exit(f"ERROR: plugins/{name} already exists")

    repl = {
        "@@NAME@@": name,
        "@@ADDON@@": name,
        "@@ZIGMOD@@": name,
        "@@LABEL@@": args.label or name,
        "@@DESC@@": args.desc,
        "@@AUTHOR@@": args.author,
        "@@RISK@@": args.risk,
        "@@FINGERPRINT@@": secrets.token_hex(8),
    }

    def render(template: str) -> str:
        for k, v in repl.items():
            template = template.replace(k, v)
        return template

    os.makedirs(os.path.join(plugin_dir, "src"))

    files = {
        "plugin.json": json.dumps(PLUGIN_JSON, indent=2, ensure_ascii=False) + "\n",
        "build.zig": BUILD_ZIG,
        "build.zig.zon": BUILD_ZON,
        "src/root.zig": ROOT_ZIG,
        "src/test.zig": TEST_ZIG,
        "test.js": TEST_JS,
        "Makefile": MAKEFILE,
    }
    for rel, content in files.items():
        path = os.path.join(plugin_dir, rel)
        with open(path, "w") as f:
            f.write(render(content))
        print(f"  created {os.path.relpath(path, ROOT)}")

    autofix_fingerprint(plugin_dir)

    print(f"\nPlugin scaffolded: plugins/{name}")
    print("Next:")
    print(f"  cd plugins/{name} && zig build test   # 单元测试")
    print(f"  make build-all                        # 2 平台产物 -> dist/")
    print("  bump plugin.json version && git push  # CI 自动构建发布")


if __name__ == "__main__":
    main()
