"use strict";
// 集成冒烟测试（需 Linux + 宿主平台 .node）：make node-test
// 交叉验证：node:zlib 解压我们的 gzip；GNU tar 解包我们的 tar.gz。
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execSync } = require("child_process");
const zlib = require("zlib");

const mod = require("./file_compress.node");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "se-compress-"));
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
    // 1. 单文件压缩 + node:zlib 交叉验证
    const srcFile = path.join(tmp, "input.txt");
    fs.writeFileSync(srcFile, "Hello ShallowEnd! ".repeat(1000));
    const gzPath = path.join(tmp, "input.txt.gz");
    const r1 = mod.compress({ source_path: srcFile, target_path: gzPath });
    console.log(r1);
    const gzRaw = fs.readFileSync(gzPath);
    check("compress writes gzip magic", gzRaw[0] === 0x1f && gzRaw[1] === 0x8b);
    check(
        "compress round trip matches original",
        zlib.gunzipSync(gzRaw).equals(fs.readFileSync(srcFile)),
    );

    // 2. level 参数
    const gzFast = gzPath + ".fast";
    mod.compress({ source_path: srcFile, target_path: gzFast, level: "fastest" });
    check(
        "level=fastest round trips",
        zlib.gunzipSync(fs.readFileSync(gzFast)).equals(fs.readFileSync(srcFile)),
    );
    const gzBest = gzPath + ".best";
    mod.compress({ source_path: srcFile, target_path: gzBest, level: "best" });
    check(
        "level=best round trips",
        zlib.gunzipSync(fs.readFileSync(gzBest)).equals(fs.readFileSync(srcFile)),
    );

    // 3. 非法 level 与同路径守卫
    let r3 = mod.compress({ source_path: srcFile, target_path: gzPath + ".x", level: "bogus" });
    check("invalid level rejected", r3 && r3.startsWith("[ERRO]"), r3);
    r3 = mod.compress({ source_path: srcFile, target_path: srcFile });
    check("same-path rejected", r3 && r3.startsWith("[ERRO]"), r3);

    // 4. 目录打包：嵌套目录/大文件/符号链接/空目录
    const srcDir = path.join(tmp, "tree");
    fs.mkdirSync(path.join(srcDir, "sub", "deep"), { recursive: true });
    fs.writeFileSync(path.join(srcDir, "a.txt"), "A".repeat(4096));
    fs.writeFileSync(path.join(srcDir, "sub", "b.txt"), "B".repeat(100000));
    fs.writeFileSync(path.join(srcDir, "sub", "deep", "c.bin"), Buffer.alloc(65536, 7));
    fs.symlinkSync("a.txt", path.join(srcDir, "sub", "a-link.txt"));
    fs.mkdirSync(path.join(srcDir, "emptydir"));
    const tgz = path.join(tmp, "tree.tar.gz");
    const r4 = mod.compressDir({ source_path: srcDir, target_path: tgz });
    console.log(r4);
    check("compressDir output exists", fs.existsSync(tgz));

    // 5. GNU tar 交叉解包验证
    const exDir = path.join(tmp, "extracted");
    fs.mkdirSync(exDir);
    execSync(`tar -xzf "${tgz}" -C "${exDir}"`);
    check("tar extracts a.txt", fs.readFileSync(path.join(exDir, "a.txt")).length === 4096);
    check(
        "tar extracts nested binary",
        fs.readFileSync(path.join(exDir, "sub/deep/c.bin")).equals(Buffer.alloc(65536, 7)),
    );
    check("tar extracts big file", fs.readFileSync(path.join(exDir, "sub/b.txt")).length === 100000);
    check(
        "symlink preserved",
        fs.readlinkSync(path.join(exDir, "sub/a-link.txt")) === "a.txt",
    );
    check("empty dir preserved", fs.statSync(path.join(exDir, "emptydir")).isDirectory());

    // 6. 超长路径（gnu L 扩展头 + @LongLink）GNU/busybox tar 均可列表
    const deep = path.join(srcDir, "l" + "o".repeat(120) + "ng");
    fs.mkdirSync(deep, { recursive: true });
    fs.writeFileSync(path.join(deep, "d.txt"), "deep");
    // 7. 超长符号链接目标（gnu K 扩展头）
    const longTarget = "t" + "a".repeat(110) + ".txt";
    fs.writeFileSync(path.join(srcDir, longTarget), "lt");
    fs.symlinkSync(longTarget, path.join(srcDir, "sub", "long-link"));
    fs.rmSync(tgz);
    mod.compressDir({ source_path: srcDir, target_path: tgz });
    const listing = execSync(`tar -tzf "${tgz}"`).toString();
    check("long path entry survives busybox tar listing", listing.includes("d.txt"), listing);
    check("long link target survives busybox tar listing", listing.includes("long-link"), listing);

    // 8. busybox 实解包长名条目
    const exDir2 = path.join(tmp, "extracted2");
    fs.mkdirSync(exDir2);
    execSync(`tar -xzf "${tgz}" -C "${exDir2}"`);
    check(
        "busybox extracts long path content",
        fs.readFileSync(path.join(exDir2, "l" + "o".repeat(120) + "ng", "d.txt")).toString() === "deep",
    );
    check(
        "busybox extracts long link target",
        fs.readlinkSync(path.join(exDir2, "sub", "long-link")) === longTarget,
    );
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}

console.log(failed === 0 ? "ALL OK" : `${failed} FAILURES`);
process.exit(failed === 0 ? 0 : 1);
