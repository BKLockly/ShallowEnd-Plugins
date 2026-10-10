# plugin-file-decompress

文件解压插件（纯 Zig 实现，无需目标机外部命令）。

## 方法

### decompress — 文件解压

将 `.gz` 文件流式解压为源文件，支持任意大小文件（全链路流式，常数内存）。

| 参数 | 必填 | 说明 |
|------|------|------|
| `source_path` | 是 | 要解压的 `.gz` 文件路径 |
| `target_path` | 是 | 输出的源文件路径 |

### decompressArchive — 归档解包

将 `.tar.gz` 归档解包到目标目录（与 `file_compress` 的 compressDir 配对）。

| 参数 | 必填 | 说明 |
|------|------|------|
| `source_path` | 是 | 要解包的 `.tar.gz` 文件路径 |
| `target_path` | 是 | 目标目录路径（不存在会自动创建） |

行为细节：

- 保留文件可执行位，忽略 setuid 等危险位
- 已存在的文件跳过（exclusive 创建），逐条列明在结果中；重复解包安全
- 归档内路径逃逸目标目录会被拒绝（tar-slip 防护）
- 输入不是有效 tar 时报错引导改用 `decompress`

## 构建 / 测试

```bash
make test        # 单元测试（zig build test，无需 Node）
make build-all   # linux-x64 + linux-arm64 产物 → dist/
make node-test   # 集成冒烟（需 Linux + 宿主平台 .node，交叉验证 node:zlib 与 GNU tar）
```
