# ShallowEnd-Plugins — 插件 Monorepo（开发规范）

市场所有插件的唯一仓库。插件用 Zig + Tokota 编译为 Node.js 原生 addon（`.node`），通过 N-API 加载，跨 Node 版本兼容。市场索引 `registry.json` 在本仓根目录，由 CI 机器人维护。

本仓**完全独立于** ShallowEnd 主仓。主仓只通过 `plugin_marketplace_url` 配置指向本仓的 `registry.json`，其余零耦合。

> 面向用户的介绍文档是 `README.md`（英文）/ `README.zh-CN.md`（中文）；本文件是开发/Agent 工作规范。

## 目录结构

```
ShallowEnd-Plugins/
├── AGENTS.md                 ← 本文件（开发规范）
├── README.md / README.zh-CN.md
├── LICENSE                   ← MIT
├── THIRD_PARTY.md            ← 第三方组件与许可证声明
├── registry.json             ← 市场索引（CI 机器人自动维护，勿手改）
├── .github/workflows/
│   └── build.yml             ← 唯一的 CI，构建/发布/更新索引
├── scripts/
│   ├── scaffold.py           ← 插件脚手架
│   └── update_registry.py    ← registry.json 更新脚本（CI 调用）
├── shared/
│   └── zig-pkg/              ← vendored 依赖（tokota），全仓唯一一份
└── plugins/
    ├── docker_detect/
    ├── bof/
    ├── hello/
    ├── linux_exploit_suggester/
    ├── file_compress/
    ├── file_decompress/
    └── sensitive_search/
```

## 平台矩阵（已拍板，2026-09-08）

| 平台 | 标识 | zig target | 状态 |
|------|------|------------|------|
| Linux x86_64 | `linux-x64` | `x86_64-linux-gnu` | 构建 |
| Linux ARM64 | `linux-arm64` | `aarch64-linux-gnu` | 构建 |
| Windows x64 | `win32-x64` | `x86_64-windows-gnu` | **不构建** |
| macOS (x64/arm64) | `darwin-*` | - | **不构建** |

决策理由：

- 主攻 Linux 目标；ARM Linux（云主机/容器）零成本保留
- Windows 无测试能力，产出即"未测试的二进制"；Node.js on Windows 靶子极少
- Darwin 目标等价于自己的 Mac，需要时本地 `zig build -Dtarget=<...>` 冒烟即可
- 客户端 `parsePlatform()` 对全平台已兼容；恢复某平台 = Makefile 加一行 + `parse_platform()` 正则已预留

**bof 例外**：使用 musl libc（`x86_64-linux-musl` / `aarch64-linux-musl`），因其静态链接 bof-launcher。

## 铁律

1. **目录名 = `plugin.json` 的 `name`**，snake_case。禁止 kebab-case 目录、禁止目录名与插件名不一致。
2. **`plugin.json` 的 `version` 是版本唯一事实源**。发布 = 改 version + push main，CI 自动打 tag / 建 release / 更新 registry。
3. **artifact 命名**：`<name>-linux-x64.node` / `<name>-linux-arm64.node`，`<name>` 即 plugin.json 的 name（snake_case）。
4. **禁止**在插件目录内放：per-plugin CI、`update_registry.py` 副本、`zig-pkg/` 拷贝。这些全仓只允许一份。
5. **tokota 依赖统一走 `../../shared/zig-pkg/`**（`build.zig.zon` 的 `.path`）。升级 tokota = 替换 shared 下目录 + 全插件 zon 同步 + 全量 CI 重编。
6. **CI 无外网**：任何构建依赖必须 vendored 进 `shared/zig-pkg/`。
7. **每个插件必须能 `zig build test`**：单元测试写在 `src/test.zig`，不得 import tokota（CI 无 Node 运行时）；需要 Node 的集成验证放 `test.js`（本地手动 `node test.js`）。
8. **`registry.json` 勿手改**，它由 CI 机器人提交；手工改动会在下次发布时被覆盖或造成漂移。
9. **禁止提交构建产物**：`dist/`、`*.node`、`.zig-cache/`、`zig-out/`、`__pycache__/` 一律不入库（.gitignore 已覆盖）。
10. **禁止硬编码任何凭据/内网地址**：CI 认证只允许 `${{ github.token }}` 或官方 actions；文档中的示例 host 一律用 `example.com` 或 GitHub URL。

## 发布流程（全自动）

```
改 plugins/<name>/plugin.json 的 version
        │
        ▼ push main
CI: 遍历 plugins/*，比对 version 与已有 tag <name>-v<version>
        │
        ├─ tag 已存在 → 跳过（幂等，重复 push 安全）
        └─ tag 不存在 → make build-all（2 平台）
                         → gh release create 建 tag + release + 上传 dist/*.node
                         → update_registry.py 合并条目进 registry.json
                         → git commit "ci: update registry ... [skip ci]" + push
```

- tag 格式：`<name>-v<version>`，如 `docker_detect-v3.0.1`
- 手动强制重编：GitHub Actions 界面 workflow_dispatch（但 version 没变则依然幂等跳过；要强制重发请改 version）
- `[skip ci]` 防止机器人提交再次触发 workflow

## registry.json schema

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
      "methods": [ ... 来自 plugin.json ... ],
      "artifacts": {
        "linux-x64":   { "filename": "...", "url": "...", "sha256": "...", "size": 123 },
        "linux-arm64": { "filename": "...", "url": "...", "sha256": "...", "size": 123 }
      }
    }
  ]
}
```

- artifact `url` 直指 GitHub Releases 下载地址；自托管 ShallowEnd 离线环境下可用本地 registry 覆盖 `plugin_marketplace_url`
- 客户端安装时按 `sha256` 校验；加载时按目标架构选 `artifacts` 中对应 key

## CI 说明

- Runner：GitHub hosted `ubuntu-latest`，Zig 0.16.0 经 `mlugg/setup-zig@v2` 安装
- 触发：push main（paths 限定 plugins/shared/scripts/registry/workflow）或手动 dispatch
- 认证：全部使用 `${{ github.token }}`（`permissions: contents: write`），无任何硬编码凭据
- 幂等性：以 tag 存在性为判据，任何原因的重复运行都安全

## 新增插件

```bash
python3 scripts/scaffold.py port_scan --label "端口扫描" --desc "TCP 端口扫描" --risk medium
cd plugins/port_scan
zig build test          # 单元测试
make build-all          # 本地冒烟（darwin 交叉编译，正式产物以 CI 为准）
# 改 src/root.zig 实现逻辑，完善 plugin.json methods
# bump version → git push → CI 自动发布
```

## 本地开发

```bash
cd plugins/<name>
make build-all   # 2 平台产物 → dist/
make test        # zig build test（无 tokota 依赖）
make node-test   # node test.js（需宿主平台 .node，本地用 zig build 产出）
make clean
```

注意：本地（如 macOS）交叉编译的 Linux 产物仅作冒烟验证，**正式分发以 CI 产物为准**。

## plugin.json schema

```json
{
  "name": "plugin_name",          // 必须 = 目录名，snake_case
  "label": "显示名称",
  "description": "描述",
  "version": "0.1.0",             // 版本唯一事实源，semver
  "author": "BKLockly",
  "risk_level": "low",            // low | medium | high
  "methods": [
    {
      "name": "method_name",      // 对应 src/root.zig 导出的 pub fn
      "label": "方法显示名",
      "description": "方法描述",
      "params": [
        {"name": "param", "type": "text|number|file|select|checkbox", "label": "参数名", "required": true}
      ]
    }
  ]
}
```

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

- 所有方法统一接收**一个 JS 对象**（前端模板传 `module[method](params)`），按名取值
- 数字/布尔多用 `getT`；字符串必须 `Val.stringAlloc(env, allocator)` 显式转换
- 返回值是字符串，交给前端 `PluginLog.vue` 渲染

### 返回文本输出格式（前端契约，必须遵守）

输出字符串按 `\n` 分行，前端按以下规则渲染：

- 行匹配 `^\[(\w+)\]\s*(.*)$` → 有 LOG 级别前缀，左侧渲染 level badge：`[INFO]`、`[WARN]`、`[ERRO]`、`[DEBU]`
- 不匹配 → 纯文本行，无 badge，`white-space: pre-wrap` 保留前导空格

```
[INFO] Available information:          ← 标题行，带 [LEVEL]
    Kernel version: 6.10.14-linuxkit   ← 子内容：4 空格缩进，无 [LEVEL]
    Architecture: arm64

[WARN] [CVE-2022-2586] nft_object UAF  ← CVE 条目正文带 [LEVEL]
    Details: https://...               ← 属性行 4 空格缩进
    Exposure: less probable
```

规则：标题行始终带 `[LEVEL]`；详情/标签/统计用 4 空格缩进且不带前缀；空行用 `\n`（空字符串行）。

## 已迁移插件版本基线

| 插件 | version | 备注 |
|------|---------|------|
| bof | 0.0.4 | musl，静态链接 lib/ 下 bof-launcher |
| docker_detect | 3.0.1 | 原 plugin-docker-detect |
| file_compress | 0.2.0 | |
| file_decompress | 0.2.0 | 原 plugin-file-decompress |
| hello | 0.2.0 | scaffold 示例插件 |
| linux_exploit_suggester | 0.2.0 | CVE 知识库参考 The-Z-Labs 上游（GPL-3.0），Zig 匹配逻辑为原创，LICENSE/CHANGELOG 保留 |
| sensitive_search | 0.14.1 | |
