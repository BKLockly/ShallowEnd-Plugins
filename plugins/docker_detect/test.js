// Test script for docker.node addon
const docker = require("./docker.node");

console.log("Testing docker addon...\n");
const result = docker.isDocker();
console.log("=== Detection Logs ===");
console.log(result.logs);
console.log("\n=== Result ===");
console.log("Confidence:", result.confidence + "%");
console.log("Test passed!");