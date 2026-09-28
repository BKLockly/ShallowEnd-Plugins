const mod = require("./file_compress.node");
const result = mod.compress({
    source_path: "/tmp/test-input.txt",
    target_path: "/tmp/test-output.txt.gz",
});
console.log(result);
