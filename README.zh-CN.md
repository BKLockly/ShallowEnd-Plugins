# ShallowEnd-Plugins

[![Build and Release](https://github.com/BKLockly/ShallowEnd-Plugins/actions/workflows/build.yml/badge.svg)](https://github.com/BKLockly/ShallowEnd-Plugins/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[ShallowEnd](https://github.com/BKLockly/ShallowEnd) 市场官方插件 monorepo。插件使用 Zig + [Tokota](https://github.com/kofi-q/tokota) 编写，编译为 Node.js 原生 addon（`.node`，N-API），跨 Node 版本兼容。市场索引 `registry.json` 位于仓库根目录，由 CI 机器人维护。

本仓与 ShallowEnd 主程序完全解耦：主程序仅通过 `plugin_marketplace_url` 配置指向本仓的 `registry.json`。

## 目录结构

```
ShallowEnd-Plugins/
├── .github/workflows/
│   └── build.yml             ← 唯一 CI：构建 / 发布 / 更新索引
├── registry.json             ← 市场索引（机器人维护，勿手改）
├── Justfile                  ← 仓库级任务入口（just test / check / new / ...）
├── scripts/
│   ├── scaffold.py           ← 插件脚手架生成器
│   ├── check_consistency.py  ← 一致性检查（CI 门禁 + 本地 just check）
│   ├── update_registry.py    ← registry.json 更新脚本（CI 调用）
│   └── update_tokota.py      ← tokota 钉版升级
├── plugins/                  ← 每个插件一个目录（依赖由 zig 包管理器解析）
└── plugins/                  ← 每个插件一个目录，目录名 = 插件名
```

## 插件列表

| 插件 | 版本 | 说明 | 风险 |
|------|------|------|------|
| bof | 0.2.0 | 加载并执行 Beacon Object Files（BOF），musl 静态链接 | high |
| docker_detect | 3.0.1 | Docker 容器环境检测 | low |
| file_compress | 0.2.0 | 纯 Zig Gzip 文件压缩 | low |
| file_decompress | 0.2.1 | 纯 Zig .gz 解压 | low |
| hello | 0.4.1 | 脚手架示例插件 | low |
| linux_exploit_suggester | 1.3 | 匹配目标内核的本地提权漏洞建议 | low |
| sensitive_search | 0.14.2 | 敏感文件/凭据搜索 | medium |
| agentscan | 0.1.0 | 内网 MCP / A2A / LLM 暴露面扫描（内嵌 AgentScan 引擎） | medium |

## 致谢

本项目建立在以下开源项目之上，一并致谢！完整许可证信息与修改说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

| 项目 | 许可证 | 用途 |
|------|--------|------|
| [AgentScan](https://github.com/7anX/AgentScan) | MIT © 2026 7anX | `agentscan` 插件（内嵌扫描引擎，vendored） |
| [bof-launcher](https://github.com/The-Z-Labs/bof-launcher) | BSD-3-Clause © 2022-2026 Z-Labs | `bof` 插件（静态链接，vendored） |
| [Tokota](https://github.com/kofi-q/tokota) | MIT © Nana Kofi Ohene-Adu | Zig → Node.js N-API 绑定工具，全插件共用 |
| [base-z](https://github.com/kofi-q/base-z) | MIT | Tokota 传递依赖 |
| [stb](https://github.com/nothings/stb) | Public Domain / MIT | bof-launcher 内 vendored 头文件 |
| [linux-exploit-suggester](https://github.com/mzet-/linux-exploit-suggester) | GPL-3.0 | `linux_exploit_suggester` 的 CVE 知识库 |
| [mysql2](https://github.com/sidorares/node-mysql2) | MIT | `mysql_driver` 插件 bundle（esbuild 打包，目标机内存加载） |
| [pg](https://github.com/brianc/node-postgres) | MIT | `pg_driver` 插件 bundle（esbuild 打包，目标机内存加载） |
| [esbuild](https://github.com/evanw/esbuild) | MIT | js 类型驱动插件的打包器 |

## 平台矩阵

| 平台 | 标识 | zig target | 构建 |
|------|------|------------|------|
| Linux x86_64 | `linux-x64` | `x86_64-linux-gnu` | ✅ |
| Linux ARM64 | `linux-arm64` | `aarch64-linux-gnu` | ✅ |
| Windows x64 | `win32-x64` | `x86_64-windows-gnu` | ❌ |
| macOS | `darwin-*` | — | ❌ |

决策理由：主攻 Linux 目标，ARM Linux（云主机/容器）零成本保留；Windows 无测试能力且 Node.js 靶面极窄；macOS 需要时本地 `zig build -Dtarget=...` 冒烟即可。**bof 例外**：musl libc 静态链接 bof-launcher。

## 发布流程（全自动）

```
修改 plugins/<name>/plugin.json 的 "version"
        │
        ▼ push 到 main
CI: 遍历 plugins/*，比对已有 tag <name>-v<version>
        │
        ├─ tag 已存在 → 跳过（幂等，重复 push 安全）
        └─ tag 不存在 → make build-all（双平台）
                        → gh release create <tag> + 上传 dist/*.node
                        → update_registry.py 合并条目进 registry.json
                        → 机器人提交 "ci: update registry ... [skip ci]"
```

- tag 格式：`<name>-v<version>`，如 `docker_detect-v3.0.1`
- 强制重编：bump version（version 未变的 dispatch 依然幂等跳过）

## Registry Schema

```json
{
  "marketplace_version": 1,
  "updated_at": "2026-09-08T00:00:00Z",
  "plugins": [
    {
      "name": "docker_detect",
      "label": "Docker 环境检测",
      "description": "...",
      "version": "3.0.1",
      "author": "BKLockly",
      "risk_level": "low",
      "repo_url": "https://github.com/BKLockly/ShallowEnd-Plugins",
      "release_url": "https://github.com/BKLockly/ShallowEnd-Plugins/releases/tag/docker_detect-v3.0.1",
      "methods": [ "..." ],
      "artifacts": {
        "linux-x64":   { "filename": "...", "url": "...", "sha256": "...", "size": 123 },
        "linux-arm64": { "filename": "...", "url": "...", "sha256": "...", "size": 123 }
      }
    }
  ]
}
```

客户端安装时按 `sha256` 校验，加载时按目标架构选择对应 artifact。

## 新增插件

```bash
just new port_scan --label "端口扫描" --desc "TCP 端口扫描" --risk medium
cd plugins/port_scan
zig build test          # 单元测试
make build-all          # 本地冒烟构建（正式产物以 CI 为准）
# 实现 src/root.zig，完善 plugin.json methods
# bump version → git push → CI 自动发布
```

## 仓库铁律（约定 + CI 共同约束）

1. **目录名 = `plugin.json` 的 `name`**，snake_case。
2. **`plugin.json` 的 `version` 是版本唯一事实源**。
3. **artifact 命名**：`<name>-linux-x64.node` / `<name>-linux-arm64.node`。
4. **禁止**在插件目录内放：per-plugin CI、`update_registry.py` 副本、vendored 依赖拷贝。
5. **tokota 通过 zig 包管理器声明**：`.url` 钉上游 commit 不可变 tarball + `.hash` 内容校验，全插件一致。
6. **禁止 vendored 依赖**：构建依赖走上游 URL + hash 锁定；zig 自动物化到本地 `zig-pkg/`（已 gitignore）。
7. **每个插件必须能 `zig build test`**：单元测试写 `src/test.zig`，不得 import tokota（CI 无 Node 运行时）；需要 Node 的集成验证放 `test.js`。
8. **`registry.json` 勿手改** —— 机器人所有。

## 本地开发

仓库级任务统一走 [just](https://github.com/casey/just)（见 `Justfile`）：

```bash
just test            # 全部插件单元测试（或 just test bof hello）
just build-all       # 所有插件正式产物 → dist/
just check           # 仓库一致性检查
just fmt / fmt-check # 格式化 / 检查（第三方源码除外）
just pre-push        # fmt-check + check + test
just new <name> ...  # 创建新插件
just update-tokota <tarball-or-url>  # 升级 tokota 钉版
just clean
```

单插件构建仍走各自目录的 `Makefile`：

```bash
cd plugins/<name>
make build-all   # 双平台产物 → dist/
make test        # zig build test（无 tokota 依赖）
make node-test   # node test.js（需宿主平台 .node）
make clean
```

注意：本地交叉编译产物仅作冒烟验证，**正式分发以 CI 产物为准**。

## 插件开发要点（Tokota）

入口 `src/root.zig`：

```zig
const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());   // 导出模块
}

pub fn myMethod(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);   // 统一接收一个 JS 对象

    const num = try params.getT("key_num", f64);
    const flag = try params.getT("key_bool", bool);
    const opt = try params.getT("key_opt", ?f64) orelse 0;

    // 字符串参数不能用 getT(_, []const u8)（tokota 0.1.0 无法推断转换），
    // 必须取 Val 后用 stringAlloc 显式转换：
    var str: []const u8 = "default";
    if (params.get("key_str")) |val| {
        if (!try val.isNullOrUndefined(call.env)) {
            str = try val.stringAlloc(call.env, std.heap.c_allocator);
        }
    } else |_| {}

    return "result string";
}
```

- 所有方法统一接收**一个 JS 对象**（前端调 `module[method](params)`），按名取值
- 数字/布尔多用 `getT`；字符串必须 `Val.stringAlloc(env, allocator)` 显式转换
- 返回值是字符串，交给客户端插件日志渲染

### 返回文本输出格式（前端契约）

输出按 `\n` 分行；匹配 `^\[(\w+)\]\s*(.*)$` 的行渲染级别徽标（`[INFO]` / `[WARN]` / `[ERRO]` / `[DEBU]`），其余行纯文本 `white-space: pre-wrap` 渲染。标题行始终带 `[LEVEL]`；详情行 4 空格缩进且不带前缀。

```
[INFO] Available information:
    Kernel version: 6.10.14-linuxkit
    Architecture: arm64

[WARN] [CVE-2022-2586] nft_object UAF
    Details: https://...
    Exposure: less probable
```

## 许可证

MIT —— 见 [LICENSE](LICENSE)。第三方组件及许可证见 [THIRD_PARTY.md](THIRD_PARTY.md)。注意：`plugins/linux_exploit_suggester/` 的 CVE 知识库衍生自 GPL-3.0 项目，该目录按 GPL-3.0 授权。

## English

See [README.md](README.md).
