const mod = require("./hello.node");
console.log("Testing hello addon...\n");
const result = mod.hello();
console.log(result);
console.log("\nTest passed!");
