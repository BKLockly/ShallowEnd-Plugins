// 完整 roundtrip 测试：模拟 payload 的 dbDriverLoad 内存加载路径（new Function），
// 覆盖 建表→写入→写回落盘→重开读取→Buffer 直开→空结果集 的全链路。
// 纯 JS（sql.js asm.js），mac/linux 均可直跑：node test.js
const fs = require("fs");
const path = require("path");
const os = require("os");
const assert = require("assert");

const src = fs.readFileSync(path.join(__dirname, "dist", "sqlite_driver.js"), "utf8");

// payload 同款加载：new Function('module','exports','require', src)
// bundle 仅 require Node 内置模块，stub 直接放行真实 require
const moduleObj = { exports: {} };
new Function("module", "exports", "require", src)(moduleObj, moduleObj.exports, require);
const api = moduleObj.exports;

assert.strictEqual(typeof api.Database, "function", "exports.Database must be a function");

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sqlite_driver_test-"));
  const dbPath = path.join(tmp, "shlabs_test.db");

  // 空文件起步（sql.js 以零字节初始化新库）
  fs.writeFileSync(dbPath, Buffer.alloc(0));

  // 建表 + 写入 + 写回
  let db = new api.Database(dbPath);
  await db.run("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, api_key TEXT)");
  const n = await db.run("INSERT INTO users (name, api_key) VALUES ('admin', 'AKIAIOSFODNN7EXAMPLE')");
  assert.strictEqual(n, 1, "insert affects 1 row");
  await db.run("INSERT INTO users (name, api_key) VALUES ('svc', 'ghp_0123456789abcdefghijklmnopqrstuvwxyz')");
  db.close();

  // 重开验证持久化写回
  db = new api.Database(dbPath);
  const rows = await db.all("SELECT id, name, api_key FROM users ORDER BY id");
  assert.strictEqual(rows.length, 2, "persisted rows readable after reopen");
  assert.strictEqual(rows[0].name, "admin");
  assert.strictEqual(rows[0].api_key, "AKIAIOSFODNN7EXAMPLE");
  assert.strictEqual(typeof rows[0].id, "number", "integer columns stay numeric");

  // 空结果集
  const none = await db.all("SELECT * FROM users WHERE name = 'nope'");
  assert.deepStrictEqual(none, []);

  // 运行时写 + 再落盘
  await db.run("UPDATE users SET name = 'root' WHERE id = 1");
  db.close();
  db = new api.Database(dbPath);
  const after = await db.all("SELECT name FROM users WHERE id = 1");
  assert.strictEqual(after[0].name, "root");

  // Buffer 直开（内存库，无写回路径）
  const bytes = fs.readFileSync(dbPath);
  const mem = new api.Database(bytes);
  const memRows = await mem.all("SELECT count(*) AS c FROM users");
  assert.strictEqual(memRows[0].c, 2);

  // 非法构造
  assert.throws(() => new api.Database(42), /Database\(path \| Buffer\)/);

  console.log("sqlite_driver test.js: all assertions passed");
})().catch((e) => {
  console.error("FAILED:", e.message);
  process.exit(1);
});
