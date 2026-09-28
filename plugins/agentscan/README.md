# agentscan

内网 MCP / A2A Agent / LLM 开放接口暴露面扫描插件。基于 [7anX/AgentScan](https://github.com/7anX/AgentScan)（MIT）实现，上游源码 vendored 于 `agentscan/` 子目录。

## 实现方式

- 构建期：`go build`（`CGO_ENABLED=0` 静态链接，GOOS 恒为 linux）→ gzip → `@embedFile` 内嵌进 `.node` addon（amd64 ~3.7MB / arm64 ~3.4MB）
- 运行期：Zig 薄壳将 payload 解压到 `/tmp/.agentscan-<随机>.d/`，fork/exec 执行并收集输出，超时（默认 600s）SIGKILL
- cwd 圈定：上游会往 CWD 写 html/txt 报告文件，payload 固定 chdir 进临时目录，运行结束后 `rm -rf` 整体清理
- 输出：ANSI 转义剥离后透传（`--no-color` 双保险），套 `[LEVEL]` 前端契约

## 方法

| 方法 | 说明 |
|------|------|
| scan | MCP + A2A + LLM 全协议扫描 |
| mcp | 只扫 MCP Server（工具/资源/提示词枚举、OAuth 发现、蜜罐信号） |
| a2a | 只扫 A2A Agent Card（`strict` 参数开精确模式） |
| llm | 只扫 LLM 开放推理接口（Ollama/vLLM/TGI 等 25 种框架） |

公共参数：`targets`（必填，逗号/空白分隔）、`threads`、`timeout`、`skip_port_scan`、`proxy`、`verbose`。

## 致谢

- [AgentScan](https://github.com/7anX/AgentScan) — MIT © 2026 7anX，完整许可声明见仓库根 [THIRD_PARTY.md](../../THIRD_PARTY.md)
