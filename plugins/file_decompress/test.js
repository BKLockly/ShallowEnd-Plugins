const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const mod = require("./file_decompress.node");

const testDir = path.join(__dirname, "test_source");
const sourceFile = path.join(__dirname, "test-input.txt");
const compressedFile = path.join(__dirname, "test-input.txt.gz");
const outputFile = path.join(__dirname, "test-output.txt");

try {
    if (fs.existsSync(testDir)) fs.rmSync(testDir, { recursive: true });
    if (fs.existsSync(sourceFile)) fs.unlinkSync(sourceFile);
    if (fs.existsSync(compressedFile)) fs.unlinkSync(compressedFile);
    if (fs.existsSync(outputFile)) fs.unlinkSync(outputFile);
} catch (e) {}

const testContent = "Hello, World! This is a test file for gzip decompression.\n".repeat(100);
fs.writeFileSync(sourceFile, testContent);

const compressed = zlib.gzipSync(testContent);
fs.writeFileSync(compressedFile, compressed);

console.log("Created test files:");
console.log("  Original:", sourceFile, `(${fs.statSync(sourceFile).size} bytes)`);
console.log("  Compressed:", compressedFile, `(${fs.statSync(compressedFile).size} bytes)`);

const result = mod.decompress({
    source_path: compressedFile,
    target_path: outputFile,
});
console.log("\nResult:");
console.log(result);

if (fs.existsSync(outputFile)) {
    const outputContent = fs.readFileSync(outputFile, "utf-8");
    const match = outputContent === testContent;
    console.log(`\nContent match: ${match ? "PASS" : "FAIL"}`);
} else {
    console.log("\nOutput file not found!");
}

try {
    fs.unlinkSync(sourceFile);
    fs.unlinkSync(compressedFile);
    fs.unlinkSync(outputFile);
} catch (e) {}
