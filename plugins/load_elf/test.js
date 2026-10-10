// 本地冒烟：需先 make build-all 产出 load_elf.node 且在 Linux 上运行。
// 完整执行链测试由 `make test`（zig build test）在 Linux 下覆盖。
const mod = require("./load_elf.node");

console.log("Testing load_elf addon...");
console.log("exported methods:", Object.keys(mod));

if (typeof mod.execElf !== "function") {
  console.error("execElf method missing!");
  process.exit(1);
}

// 真实执行链冒烟：跑 /bin/echo（memfd 路径）
const fs = require("fs");
const elf = fs.readFileSync("/bin/echo");
mod
  .execElf({ elf_file: elf, args: "smoke-ok", timeout: 30 })
  .then((out) => {
    console.log(out);
    if (!out.includes("smoke-ok") || !out.includes("mode=memfd")) {
      console.error("unexpected execElf output!");
      process.exit(1);
    }
    console.log("Test passed!");
  })
  .catch((e) => {
    console.error("execElf failed:", e.message);
    process.exit(1);
  });
