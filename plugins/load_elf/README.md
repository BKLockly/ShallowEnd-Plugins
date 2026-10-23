# load_elf

内存 ELF 加载执行插件。把 ELF 二进制上传到目标机，经 `memfd_create(2)` + `execveat(2, AT_EMPTY_PATH)` 直接从内存执行，全程零落地。

> risk_level: **high** —— 任意代码执行能力。仅在授权测试环境使用。

## 工作原理

1. **主路径（零落地）**：`memfd_create("", MFD_CLOEXEC)` 创建匿名内存文件（名字传空串，`/proc/<pid>/fd` 中仅显示 `/memfd:` 前缀）→ 写入 ELF → fork → 子进程 `execveat(fd, "", argv, envp, AT_EMPTY_PATH)`。
2. **降级路径（同样无残留）**：memfd 不可用（内核 < 3.17 或被 seccomp 拦截）时先尝试 **O_TMPFILE**——在 `/tmp` 打开一个从不关联任何路径名的无名 inode（内核 ≥ 3.11 且文件系统支持）；仍不可用（老内核或 overlayfs 等不支持）再在 `/tmp` 创建 0700 临时文件写入 ELF 后**立即 unlink**。两种降级仅以 fd 引用执行（`execveat` + `AT_EMPTY_PATH`）——即使进程被 SIGKILL 也不会留下任何路径。
3. **exec 降级链**（子进程内）：`execveat(AT_EMPTY_PATH)` → 老内核无 execveat 时退 `execve("/proc/self/fd/N")`（跟随 procfs symlink）→ 全败 exit 126。
4. **异步执行**：fork + waitpid 在 libuv 线程池执行（返回 Promise），不阻塞目标机 Node 事件循环，webshell 其他请求不受影响。
5. stdout/stderr 合并收集，超时**按进程组 SIGKILL**（子进程 fork 后 `setsid` 自成进程组，`kill(-pid)` 组杀整组——ELF 拉起的孙进程一并收割；拖干管道残余输出后 waitpid 回收，不留僵尸）。

环境变量默认继承目标机 Node 进程的 environ，并强制追加 `NO_COLOR=1`。

内核要求：memfd 路径 ≥ 3.19（2015）；O_TMPFILE 路径 ≥ 3.11（2012，依赖 `/tmp` 所在文件系统支持，不支持时自动跳过该档位）；Docker 默认 seccomp 白名单允许 `memfd_create` / `execveat`。

## 方法

### execElf

| 参数 | 类型 | 必填 | 说明 |
|------|------|:---:|------|
| `elf_file` | file | ✅ | ELF 二进制（建议静态编译；动态链接需目标机有对应 so） |
| `args` | text | — | 命令行参数，空白分隔直接组 argv（不经 shell，无注入歧义；引号按字面量处理） |
| `timeout` | number | — | 超时秒数，默认 60，上限 1700（主仓请求级超时上限 1800 之内） |

argv[0] 固定为 `elf`（file 参数经 payload 解码后文件名被 Buffer 覆盖，不可得）。

## 输出契约

```
[INFO] load_elf exec: mode=memfd (in-memory) size=1234567B timeout=60s
<stdout+stderr 合并正文，ANSI 序列已剥离>
[INFO] exit code: 0
```

- `mode=memfd (in-memory)` / `mode=otmp (memfd unavailable, O_TMPFILE, never named)` / `mode=anon-tmpfile (memfd unavailable, unlinked before exec)` 回报实际执行路径
- 输出超过 1MB 截断并附加 `[WARN] output truncated`
- 超时：`[WARN] process exceeded run timeout (60s) and was killed`
- 非 0 退出：`[WARN] exited with code N`

## 限制

- 仅支持真正的 ELF；`#!` 解释器脚本不行（magic 预检直接报错）
- 动态链接的 ELF 依赖目标机 libc 及对应架构（x86_64 / aarch64）
- stdin 未接入（一次性执行模型）；常驻/驻留场景（beacon 类）暂不支持
