// v0.15.0 起 search 返回 Promise（asyncTask 异步化），必须 await；
// 断言输出含统计行，防「打印 Promise { <pending> } 也算过」的假冒烟。
const mod = require("./sensitive_search.node");
console.log("Testing sensitive_search addon...\n");

mod.search()
  .then((result) => {
    if (typeof result !== "string") throw new Error(`expected string output, got ${typeof result}`);
    if (!result.includes("[INFO] Platform:")) throw new Error("missing platform line");
    if (!result.includes("Total scanned:")) throw new Error("missing scan stats");
    console.log(result);
    console.log("\nTest passed!");
    process.exitCode = 0;
  })
  .catch((err) => {
    console.error("Test failed:", err);
    process.exitCode = 1;
  });
