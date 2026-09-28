const mod = require("./agentscan.node");
console.log("Testing agentscan addon...\n");
console.log("exports:", Object.keys(mod).join(", "));

// 非 Linux host 上 payload 是 Linux ELF，方法会优雅返回 [ERRO] 文本而不是抛异常
const result = mod.scan({ targets: "127.0.0.1", threads: 8, timeout: 500 });
console.log(result);

console.log("\nTest passed!");
