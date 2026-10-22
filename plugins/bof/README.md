# bof

加载并执行 [Beacon Object Files](https://www.z-labs.eu/)（BOF / COFF）的 ShallowEnd 原生插件，基于
[Z-Labs bof-launcher](https://github.com/The-Z-Labs/bof-launcher)（BSD-3-Clause，静态链接）。

## 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `bof_file` | file | 要执行的 COFF 文件（`.o`） |
| `args` | text | 传参；默认按 Cobalt Strike 惯例**整串单参**（BOF 侧 `entrypoint(char*, int)` 自行解析） |
| `zlab_args` | checkbox | **Z-Labs 多参数模式**：按空白拆分 `args` 逐个传参，前缀类型由 bof-launcher 解析——`i:`（u32）、`s:`（u16）、`str:` / `z:`（字符串） |

两种传参模式对应社区两类 BOF 约定：公共 CS 风格 BOF 用默认整串；Z-Labs 自家
（`bofparam` 风格）BOF 勾选多参模式。`args` 为空时两种模式都不传参。

## 对象格式（重要）

bof-launcher 的加载器是**编译期分支**：Linux 宿主只加载 **ELF relocatable**（`.elf` 目标文件），
COFF 仅 Windows 宿主可用——公共 CS 风格 COFF 在 Linux 靶机上永远加载不了。可直接使用的现成
BOF：[Z-Labs 官方集合](https://github.com/The-Z-Labs/bof-launcher)（`bofs/` 目录，zig 0.15.1 构建，
产物如 `whoami.elf.x64.o`），其参数用 `bofparam` 前缀语法（配合 `zlab_args` 勾选）。
另需 `bofLauncherInit()`（v0.3.1 修复：未初始化时加载恒失败）。

## 行为

- v0.3.0 起 COFF/ELF 加载与执行在 **libuv 线程池异步执行**（返回 Promise），不再阻塞目标机 Node 事件循环。
- 解析失败 / 运行失败以 `[ERRO]` 结果文本 resolve（是工具结果，不是异常）。
- **固有限制**：BOF 在当前进程内执行，没有子进程可 kill——卡死的 BOF 会占住一个 worker 线程且
  Promise 永不返回（事件循环与其他功能不受影响，但该次调用无法恢复）。请只运行可信 BOF。
- 仅 Linux 目标（x64 / aarch64）；bof-launcher 静态库已 vendored 在 `lib/`。

## 构建

```sh
make build-all   # 交叉编译 → dist/bof-linux-{x64,arm64}.node
make test        # zig build test（语义分析，napi 符号由 Node 运行时提供）
make node-test   # Node 冒烟（需先产出宿主平台 .node）
```

## 许可

- 本插件：MIT（随仓库）
- bof-launcher：BSD-3-Clause（见 `THIRD_PARTY.md` 与 `bof-launcher/` 内的 upstream LICENSE）
