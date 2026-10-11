// 本地形状测试：真连接测试由靶场容器 e2e 覆盖（bundle 拷入 73649 容器经
// shlabs-net 连 shlabs-redis）。CI 无 redis 服务，仅校验导出形状。
const mod = require("./dist/redis_driver.js");

if (typeof mod.createClient !== "function") {
  console.error("bad exports: createClient missing!");
  process.exit(1);
}
console.log("redis_driver exports ok (createClient present)");
