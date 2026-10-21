// 集成冒烟（需 Linux + 宿主平台 .node）：先 zig build 产出 bof.node
// 验证异步契约：垃圾 COFF 应以 [ERRO] 结果文本 resolve（不 reject、不崩进程）
const mod = require("./bof.node");

console.log("Testing bof addon...");
console.log("exported methods:", Object.keys(mod));

if (typeof mod.executeBof !== "function") {
  console.error("executeBof method missing!");
  process.exit(1);
}

mod
  .executeBof({ bof_file: Buffer.from("not a coff at all"), args: "", zlab_args: false })
  .then((out) => {
    if (!out.includes("[ERRO]")) {
      console.error("expected [ERRO] result text for garbage COFF, got:", out);
      process.exit(1);
    }
    console.log(out);
    console.log("Test passed!");
  })
  .catch((e) => {
    console.error("executeBof should resolve with [ERRO] text, not reject:", e.message);
    process.exit(1);
  });
