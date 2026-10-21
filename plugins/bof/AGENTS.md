# AGENTS.md — plugin-bof

Zig 0.16.0 NAPI native addon for Node.js (via tokota framework). Loads and runs Beacon
Object Files (COFF) in-process via the vendored bof-launcher static library.

## Build & commands

```sh
zig build test              # Linux 目标上语义分析 root.zig（napi 符号由 Node 提供，generated_bin=null）
make build-all              # 交叉编译 .node → dist/
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall   # Dev build → bof.node
node test.js                # Node 冒烟：垃圾 COFF 须以 [ERRO] 文本 resolve
```

## Source layout

| File | Responsibility |
|---|---|
| `src/root.zig` | NAPI entrypoint：参数解析、BofTask（AsyncWorker + Promise）、bof-launcher C 调用 |
| `src/test.zig` | 语义分析入口（Linux 门控，链接 vendored 静态库，generated_bin=null 不执行） |
| `lib/` | vendored bof-launcher 预编译静态库（`linux-x64/`、`linux-arm64/`）与头文件 |
| `bof-launcher/` | upstream 源码（仅浏览用，构建走 `lib/` 预编译产物） |

## Key facts

- **线程模型**：`executeBof` 在 JS 线程做参数提取（Buffer → 堆拷贝），COFF 加载/执行在
  libuv worker（`asyncWorkerT`），Promise resolve/reject 回 JS 线程。堆状态所有权：
  `bof_bytes`/`args_text` 由 `executeBof` 创建、`prepare` 成功后移交 task（agentscan cmd_args
  同款模式），失败路径手动释放——勿再加外层 errdefer 双重释放。
- **错误契约**：COFF 解析/运行失败 = `[ERRO]` 文本 resolve；OOM = reject。test.js 依赖该契约。
- **传参两模式**：默认 CS 单 blob（整串一次 `bofArgsAdd`）；`zlab_args` 勾选后逐 token `bofArgsAdd`
  （`i:`/`s:`/`str:`/`z:` 前缀由 bof-launcher 解析）。`args` 为空一律不加参数。
- **无法超时杀死**：BOF 在当前进程内执行，卡死占住 worker 线程且 Promise 永不返回——README 已声明。
- **平台**：仅 Linux x64/aarch64；bof-launcher 静态库与目标无关，产物按 gnu 链接（v0.3.0 起，
  musl 产物会 DT_NEEDED "libc.so" 在 glibc 靶机无法加载——历史 v0.2.0 release 有此问题）。
- **Clean:** `rm -f bof.node` after dev build.
