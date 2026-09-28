#!/usr/bin/env python3
"""
Bump the pinned tokota dependency across the whole repo.

Usage:
    python3 scripts/update_tokota.py <archive-url> [--hash PKG_HASH]

The argument is anything `zig fetch` accepts — typically the immutable
archive URL of an upstream commit:

    https://github.com/kofi-q/tokota/archive/<commit-sha>.tar.gz

On networks where zig's HTTP client cannot reach GitHub, precompute the hash
locally and pass it explicitly:

    zig fetch /path/to/tokota-<sha>.tar.gz   # prints tokota-x.y.z-<hash>
    python3 scripts/update_tokota.py https://github.com/kofi-q/tokota/archive/<sha>.tar.gz --hash <printed-hash>

The script:
  1. runs `zig fetch <arg>` to compute the content hash
  2. rewrites `.url` + `.hash` in every plugins/*/build.zig.zon and in the
     scaffold template (scripts/scaffold.py)
  3. prints follow-up steps

NOTE: only pin archive URLs that embed a full commit SHA — mutable URLs
(branch names, `main`) defeat the content-hash supply-chain guarantee.
"""

import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ZON_BLOCK = re.compile(
    r'(\.tokota = \.\{\s*\.url = )"[^"]+"(,\s*\.hash = )"[^"]+"(,\s*\},)'
)


def main() -> int:
    args = sys.argv[1:]
    if not args or "--hash" in args and len(args) != 3 or ("--hash" not in args and len(args) != 1):
        print(__doc__)
        return 1
    source = args[0]
    if not source.startswith("https://"):
        print("ERROR: .url must be an https archive URL embedding a commit SHA")
        return 1

    if "--hash" in args:
        pkg_hash = args[args.index("--hash") + 1]
    else:
        print(f"== zig fetch {source}")
        # zig fetch 需要在含 build.zig 的目录上下文中执行
        hello = os.path.join(ROOT, "plugins", "hello")
        r = subprocess.run(["zig", "fetch", source], capture_output=True, text=True, cwd=hello)
        if r.returncode != 0:
            print(r.stdout + r.stderr)
            print("ERROR: zig fetch failed (offline? compute the hash locally and pass --hash)")
            return 1
        pkg_hash = r.stdout.strip().splitlines()[-1].strip()

    if not re.fullmatch(r"tokota-[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9_-]+", pkg_hash):
        print(f"ERROR: unexpected hash output: {pkg_hash!r}")
        return 1
    url = source

    changed = 0
    for zonf in sorted(glob.glob(os.path.join(ROOT, "plugins", "*", "build.zig.zon"))):
        src = open(zonf).read()
        new, n = ZON_BLOCK.subn(rf'\g<1>"{url}"\g<2>"{pkg_hash}"\g<3>', src)
        if n != 1:
            print(f"ERROR: tokota block not found/ambiguous in {zonf}")
            return 1
        open(zonf, "w").write(new)
        changed += 1
        print(f"updated {os.path.relpath(zonf, ROOT)}")

    scaffold = os.path.join(ROOT, "scripts", "scaffold.py")
    src = open(scaffold).read()
    new, n = ZON_BLOCK.subn(rf'\g<1>"{url}"\g<2>"{pkg_hash}"\g<3>', src)
    if n != 1:
        print(f"ERROR: tokota block not found in scaffold template")
        return 1
    open(scaffold, "w").write(new)
    print(f"updated {os.path.relpath(scaffold, ROOT)}")

    print(f"\nDone: {changed} zons + scaffold template now pin {pkg_hash}")
    print("Next steps:")
    print("  just test        # 全量回归")
    print("  git commit ...   # 提交钉版升级（一个插件一个 PR 建议）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
