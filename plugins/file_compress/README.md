# plugin-file-compress

文件压缩插件（纯 Zig 实现，无需目标机外部命令）。

## 方法

### compress — 文件压缩

将单个文件流式压缩为 `.gz`（gzip），支持任意大小文件（全链路流式，常数内存）。

| 参数 | 必填 | 说明 |
|------|------|------|
| `source_path` | 是 | 要压缩的文件路径 |
| `target_path` | 是 | 输出的 `.gz` 文件路径 |
| `level` | 否 | gzip 压缩级别：`fastest` / `default` / `best`，默认 `default` |

### compressDir — 目录打包

将整个目录递归打包为 `.tar.gz`（walk → tar → gzip 全流式管线）。

| 参数 | 必填 | 说明 |
|------|------|------|
| `source_path` | 是 | 要打包的目录路径 |
| `target_path` | 是 | 输出的 `.tar.gz` 文件路径 |
| `level` | 否 | gzip 压缩级别，默认 `fastest`（打包偏重传输速度） |

行为细节：

- 归档内条目路径相对 `source_path`；目录条目先于其内容
- 保留文件权限（八进制 mode）与 mtime；符号链接保留为 link 条目
- fifo / socket / 设备文件跳过并在结果中列明
- 任意条目内容写入失败即中止并删除半成品归档（防止产出损坏的 tar 流）
- 超长路径（ustar 上限外）自动走 GNU 扩展头，GNU tar 可正常解包

## 构建 / 测试

```bash
make test        # 单元测试（zig build test，无需 Node）
make build-all   # linux-x64 + linux-arm64 产物 → dist/
make node-test   # 集成冒烟（需 Linux + 宿主平台 .node，交叉验证 node:zlib 与 GNU tar）
```
