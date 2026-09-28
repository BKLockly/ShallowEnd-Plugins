# ShallowEnd-Plugins — 仓库级任务入口
# 插件目录内的 Makefile 只管单插件构建（build/test/node-test/clean），
# 本文件管全仓工作流。`just` 无参列出全部命令。

default:
    @just --list

# 运行单元测试（全部插件，或指定一个/多个：just test bof hello）
test *plugins:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ $# -gt 0 ]; then
        dirs=(); for p in "$@"; do dirs+=("plugins/$p"); done
    else
        dirs=(plugins/*/)
    fi
    for d in "${dirs[@]}"; do
        [ -f "$d/build.zig" ] || continue
        echo "== zig build test: $d"
        (cd "$d" && zig build test)
    done

# 构建全部插件的正式产物（linux-x64/arm64 → 各自 dist/）
build-all:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in plugins/*/; do
        [ -f "$d/Makefile" ] || continue
        make -C "$d" build-all
    done

# 构建单个插件
build plugin:
    make -C plugins/{{plugin}} build-all

# Node 集成冒烟（需先 zig build 出宿主平台 .node）
node-test plugin:
    make -C plugins/{{plugin}} node-test

# 代码格式化（第三方 bof-launcher 与缓存目录除外）
fmt:
    #!/usr/bin/env bash
    find plugins -path '*/bof-launcher' -prune -o -path '*/.zig-cache' -prune -o \
      -path '*/zig-pkg' -prune -o \( -name '*.zig' -o -name 'build.zig.zon' \) -print0 \
      | xargs -0 zig fmt

# 格式检查（CI 同款）
fmt-check:
    #!/usr/bin/env bash
    find plugins -path '*/bof-launcher' -prune -o -path '*/.zig-cache' -prune -o \
      -path '*/zig-pkg' -prune -o \( -name '*.zig' -o -name 'build.zig.zon' \) -print0 \
      | xargs -0 zig fmt --check

# 仓库一致性检查（name/semver/zon/registry/tokota 钉版/禁放文件）
check:
    python3 scripts/check_consistency.py

# 创建新插件（flags 不得含空格；带空格的 label/desc 请创建后编辑 plugin.json）：
#   just new port_scan --risk medium
new name *opts:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 scripts/scaffold.py "{{name}}" {{opts}}

# 升级 tokota 钉版：just update-tokota <commit-tarball-url 或本地 tarball 路径>
update-tokota source:
    python3 scripts/update_tokota.py {{source}}

# 推送前全量自查（fmt + consistency + test）
pre-push: fmt-check check test

# 清理构建产物与物化依赖
clean:
    #!/usr/bin/env bash
    for d in plugins/*/; do [ -f "$d/Makefile" ] && make -C "$d" clean; done
    find . -name zig-pkg -type d -prune -exec rm -rf {} +
