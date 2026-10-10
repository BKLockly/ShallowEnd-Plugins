"use strict";
// 集成冒烟测试（需 Linux + 宿主平台 .node）：make node-test
// 交叉验证：node:zlib 压缩源数据喂给我们解；GNU tar 造 tar.gz 喂给我们解包。
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");
const zlib = require("zlib");

const mod = require("./file_decompress.node");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "se-decompress-"));
let failed = 0;
function check(name, cond, extra) {
    if (cond) {
        console.log(`[ok] ${name}`);
    } else {
        failed++;
        console.error(`[FAIL] ${name}${extra ? " :: " + String(extra) : ""}`);
    }
}

try {
    // 1. 单文件解压：源数据由 node:zlib 压缩（交叉验证）
    const orig = Buffer.from("ShallowEnd decompress smoke test. ".repeat(500));
    const gzPath = path.join(tmp, "input.txt.gz");
    fs.writeFileSync(gzPath, zlib.gzipSync(orig));
    const outFile = path.join(tmp, "input.txt");
    const r1 = mod.decompress({ source_path: gzPath, target_path: outFile });
    console.log(r1);
    check("decompress matches original", fs.readFileSync(outFile).equals(orig));

    // 2. 同路径守卫
    const r2 = mod.decompress({ source_path: gzPath, target_path: gzPath });
    check("same-path rejected", r2 && r2.startsWith("[ERRO]"), r2);

    // 3. 归档解包：GNU tar 造包（含嵌套/可执行位/符号链接）
    const srcDir = path.join(tmp, "src");
    fs.mkdirSync(path.join(srcDir, "sub"), { recursive: true });
    fs.writeFileSync(path.join(srcDir, "run.sh"), "#!/bin/sh\necho hi\n");
    fs.chmodSync(path.join(srcDir, "run.sh"), 0o755);
    fs.writeFileSync(path.join(srcDir, "sub", "data.bin"), Buffer.alloc(32768, 9));
    fs.symlinkSync("run.sh", path.join(srcDir, "sub", "sh-link"));
    const tgz = path.join(tmp, "src.tar.gz");
    execSync(`tar -czf "${tgz}" -C "${srcDir}" .`);

    const outDir = path.join(tmp, "out");
    const r3 = mod.decompressArchive({ source_path: tgz, target_path: outDir });
    console.log(r3);
    check("archive extracted run.sh", fs.readFileSync(path.join(outDir, "run.sh")).toString().includes("echo hi"));
    check("executable bit preserved", !!(fs.statSync(path.join(outDir, "run.sh")).mode & 0o100));
    check(
        "nested binary matches",
        fs.readFileSync(path.join(outDir, "sub/data.bin")).equals(Buffer.alloc(32768, 9)),
    );
    check("symlink preserved", fs.readlinkSync(path.join(outDir, "sub/sh-link")) === "run.sh");

    // 4. 重复解包：已存在文件跳过并在结果中列明
    const r4 = mod.decompressArchive({ source_path: tgz, target_path: outDir });
    console.log(r4);
    check("re-extract reports skips", r4 && r4.includes("[WARN]"), r4);
    check("existing file intact", fs.readFileSync(path.join(outDir, "run.sh")).toString().includes("echo hi"));

    // 5. 非 tar 的 .gz 报错引导
    const r5 = mod.decompressArchive({ source_path: gzPath, target_path: path.join(tmp, "nope") });
    check("plain gz rejected by decompressArchive", r5 && r5.startsWith("[ERRO]"), r5);
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}

console.log(failed === 0 ? "ALL OK" : `${failed} FAILURES`);
process.exit(failed === 0 ? 0 : 1);
