const mod = require("./sensitive_search.node");
console.log("Testing sensitive_search addon...\n");
const result = mod.search();
console.log(result);
console.log("\nTest passed!");
