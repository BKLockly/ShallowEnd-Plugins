# redis_driver

Redis 数据库驱动插件（js 类型）。基于 [node-redis](https://github.com/redis/node-redis)（官方 Redis 客户端，纯 JS）4.x 打包，经 payload `dbDriverLoad` 内存加载。

## 语义

Redis 是命令式 KV 存储，不是 SQL——payload 侧把 `execSql` 字段承载 **Redis 命令行**（如 `GET session:xxx`、`SCAN 0 MATCH user:* COUNT 100`、`INFO keyspace`），空格/引号分词后经 `sendCommand` 执行：

- 结果统一渲染为表格：标量 → 单行、数组 → 多行（key 列表 / SCAN 游标对）；
- 树浏览映射：库层 = `CONFIG GET databases` 展开 db0..N、表层 = `SCAN 0 MATCH * COUNT 100`（不用 `KEYS *`，大库阻塞风险）、列层 = `TYPE`；
- 连接参数：host/port/password（AUTH），"数据库"字段承载 **db 编号**（0-15，SELECT）；
- `SELECT 1` 是切库不是查询——连接测试由 Go 侧对 redis 发 `PING`。

## 限制

- 写命令（SET/DEL/FLUSHALL）经查询执行器直接生效，目标机 redis 无事务回滚概念，谨慎操作；
- SCAN 语义为游标迭代，树浏览固定游标 0、COUNT 100（超量 key 不全量展示）；
- RESP3/cluster 模式未适配（单机 redis 为渗透主场景）。

## 构建

```bash
make build-all   # npm install + esbuild bundle（--minify，单文件 CJS ~700KB）
make test        # 导出形状检查
```

## 致谢

- [node-redis](https://github.com/redis/node-redis)（MIT）—— Redis 官方 Node.js 客户端。
