<!-- 插件 PR：确保只动一个插件 / 工具链改动请注明影响面 -->

## What

<!-- 一句话：改了哪个插件/哪层工具链，为什么 -->

## Checklist

- [ ] `plugin.json` version 已按语义化变更 bump（patch/minor/major）
- [ ] `just fmt-check` 通过
- [ ] `just check` 通过
- [ ] `just test`（至少覆盖受影响插件）通过
- [ ] 输出文本遵守 `[LEVEL]` 行契约（AGENTS.md）
- [ ] 未触碰 `registry.json`（CI 机器人维护）
- [ ] 未引入 vendored 依赖；如升级 tokota，全仓 zon 已同步同一 commit
