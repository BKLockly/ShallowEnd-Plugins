// Test script for docker_detect addon（addon 产物名为 docker.node）
const docker = require("./docker.node");

console.log("Testing docker_detect addon...\n");
const result = docker.detect();
console.log("=== Detection Logs ===");
console.log(result);
console.log("\nTest passed!");
