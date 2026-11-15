// 本地冒烟：需先 make build-all 产出 load_elf.node 且在 Linux 上运行。
// 完整执行链测试由 `make test`（zig build test）在 Linux 下覆盖。
// 注意：GH runner 镜像把 /bin/echo、/bin/sleep 等换成了带执行名校验的加固
// 包装器（~11.8MB，拒绝 /memfd: 伪装执行，报 "Security violation" 退出 95）
// ——memfd 冒烟载荷必须用未加固的 /bin/sh（zig 单测同款选择）。
const mod = require("./load_elf.node");

console.log("Testing load_elf addon...");
console.log("exported methods:", Object.keys(mod));

if (typeof mod.execElf !== "function") {
  console.error("execElf method missing!");
  process.exit(1);
}

// 真实执行链冒烟：跑 /bin/sh -c echo（memfd 路径；echo builtin 打印空行，
// 验证 exec + 输出收集 + 退出码整链）。args 不含 argv[0]，显式传 argv0。
const fs = require("fs");
const elf = fs.readFileSync("/bin/sh");
mod
  .execElf({ elf_file: elf, argv0: "sh", args: "-c echo", timeout: 30 })
  .then((out) => {
    console.log(out);
    if (!out.includes("mode=memfd") || !out.includes("[INFO] exit code: 0")) {
      console.error("unexpected execElf output!");
      process.exit(1);
    }
    console.log("Test passed!");
  })
  .catch((e) => {
    console.error("execElf failed:", e.message);
    process.exit(1);
  });
