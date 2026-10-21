const mod = require("./hello.node");

console.log("Testing hello addon...");
console.log("exported methods:", Object.keys(mod));

const hello = mod.sayHello();
const sum = mod.add({ a: 2, b: 3 });
console.log(hello);
console.log(sum);

if (!hello.includes("Hello from Zig") || !sum.includes("5")) {
  console.error("unexpected output!");
  process.exit(1);
}
console.log("\nTest passed!");
