# reverse_shell

在目标机派生连回 listener 的 shell 会话的 ShallowEnd 原生插件。

## 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `host` | text | listener 地址（IP 或域名；IPv6 用 `[::1]:4444` 括号形式） |
| `port` | number | listener 端口 |
| `variant` | text | 变体，默认 `native`：`native`（目标进程内 socket+dup2+/bin/sh -i，零依赖）、`bash`（/dev/tcp，需 bash）、`python`（python3 pty.spawn）、`nc`（传统 netcat -e） |
| `timeout` | number | connect 超时秒数，默认 10，上限 120 |

- **native 变体**：目标进程内直接 `socket + connect + dup2(0/1/2) + exec /bin/sh -i`，
  不依赖目标机任何解释器；返回真实连接结果。
- **解释器变体**：命令串经 `/bin/sh -c` 执行，返回派生结果（连接成功与否取决于目标机
  解释器行为，无法回传）。bash 变体显式调用 `bash`（/bin/sh 可能是 dash，不识别
  /dev/tcp）。
- 会话通过 **setsid 脱离进程组**：目标机 Node 进程退出不影响已建立的 shell 会话。
- libuv 线程池异步执行（返回 Promise），不阻塞目标机 Node 事件循环。

## 风险提示（risk=high）

- 派生的 shell 会话**无法从插件侧终止**（没有记录 PID 的接口）；测试时务必自行
  管理监听端。
- 仅 Linux 目标（x64 / aarch64）。

## 构建

```sh
make build-all   # 交叉编译 → dist/reverse_shell-linux-{x64,arm64}.node
make test        # zig build test（纯逻辑用例全平台真跑；e2e 用例仅 Linux）
make node-test   # Node 冒烟（需先产出宿主平台 .node，且宿主为 Linux）
```

## 许可

MIT（随仓库）。
