# sqlite_driver

SQLite 数据库驱动插件（js 类型）。基于 [sql.js](https://github.com/sql-js/sql.js)（SQLite C 引擎的 asm.js 纯 JS 构建）打包，经 payload `dbDriverLoad` 内存加载，零落地、零 Node 版本依赖。

## 为什么是 sql.js

- `better-sqlite3` / `sqlite3` 均为 native binding：esbuild 打不了、目标机架构还得匹配；
- Node 22.5+ 内置 `node:sqlite` 但 22.x 需 `--experimental-sqlite` 启动 flag，目标机参数不可控；
- sql.js 的 asm.js 单文件构建（`dist/sql-asm.js`）零外部资源，是唯一的纯 JS 分发形态。

## 语义

SQLite 是嵌入式文件数据库，无服务器可连——payload 侧 `dbHost` 字段承载**目标机上的 .db 文件路径**：

- `new Database(path)`：`fs.readFileSync` 整库读入内存（sql.js 本身就是内存库形态），文件 > 256MB 直接报错（保护宿主 Node 不被 OOM 拖死）；
- `all(sql)`：返回行对象数组（payload 由 `Object.keys(rows[0])` 推导列名）；
- `run(sql)`：执行后**自动全量 export 写回源文件**——渗透场景查询为主，写回保证 UPDATE/DDL 不骗人；
- `close()`：同步释放。

## 限制

- **非事务安全**：整库 export 写回，目标机进程若并发写同一 .db 文件会互相覆盖；对高写入目标建议只读使用；
- 整库内存形态，大库（>256MB）拒绝打开；
- 性能低于 native binding（asm.js），交互式查询场景无感。

## 构建

```bash
make build-all   # npm install + esbuild bundle（--minify，单文件 CJS）
make test        # 导出形状检查
make node-test   # 完整 roundtrip（模拟 payload new Function 加载路径）
```

## 致谢

- [sql.js](https://github.com/sql-js/sql.js)（MIT）—— SQLite C 引擎的 Emscripten 构建。
