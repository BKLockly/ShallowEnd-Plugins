#!/usr/bin/env python3
"""
Consistency checks for the plugin monorepo. Run locally and in CI before release.

Checks:
  1. plugin.json `name` == directory name (snake_case)
  2. plugin.json `version` is strict semver (X.Y.Z)
  3. build.zig.zon `version` == plugin.json `version`
  4. every plugin pins the same tokota url+hash
  5. registry.json entry exists and matches plugin.json
     (version / label / description / author / risk_level / methods)
  6. no forbidden files inside plugin dirs (per-plugin CI, registry script copies, vendored deps)
"""

import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FORBIDDEN = [".github", ".gitea", "update_registry.py", "zig-pkg", ".gitea/workflows"]
SEMVER = re.compile(r"\d+\.\d+\.\d+")


def fail(msg: str) -> None:
    print(f"ERROR: {msg}")
    global failures
    failures += 1


failures = 0


def main() -> int:
    plugin_dirs = sorted(glob.glob(os.path.join(ROOT, "plugins", "*")))
    plugin_dirs = [d for d in plugin_dirs if os.path.isdir(d)]

    if not plugin_dirs:
        fail("no plugin directories found")
        return 1

    tokota_refs = set()
    registry = json.load(open(os.path.join(ROOT, "registry.json")))
    registry_by_name = {p["name"]: p for p in registry["plugins"]}

    for d in plugin_dirs:
        name = os.path.basename(d)

        pj_path = os.path.join(d, "plugin.json")
        if not os.path.exists(pj_path):
            fail(f"{name}: missing plugin.json")
            continue
        pj = json.load(open(pj_path))

        # 1. dir name == plugin.json name
        if pj.get("name") != name:
            fail(f"{name}: plugin.json name={pj.get('name')!r} != dir name")
        if not re.fullmatch(r"[a-z0-9_]+", name):
            fail(f"{name}: dir name not snake_case")

        # 2. strict semver
        if not SEMVER.fullmatch(pj.get("version", "")):
            fail(f"{name}: version {pj.get('version')!r} is not strict semver (X.Y.Z)")

        # 3. zon version sync
        zon_path = os.path.join(d, "build.zig.zon")
        zon = open(zon_path).read()
        m = re.search(r'\.version = "([^"]+)"', zon)
        if not m or m.group(1) != pj["version"]:
            fail(f"{name}: build.zig.zon version {m.group(1) if m else None!r} != plugin.json {pj['version']!r}")

        # 4. tokota pin consistency
        mu = re.search(r'\.tokota = \.\{\s*\.url = "([^"]+)",\s*\.hash = "([^"]+)",', zon)
        if not mu:
            fail(f"{name}: tokota dependency not declared as url+hash")
        else:
            tokota_refs.add((mu.group(1), mu.group(2)))

        # 5. registry sync
        r = registry_by_name.get(name)
        if r is None:
            fail(f"{name}: missing from registry.json")
        else:
            for k in ("version", "label", "description", "author", "risk_level"):
                if r.get(k) != pj.get(k):
                    fail(f"{name}: registry {k}={r.get(k)!r} != plugin.json {pj.get(k)!r}")
            if r.get("methods") != pj.get("methods"):
                fail(f"{name}: registry methods differ from plugin.json")
            tag = f"{name}-v{pj['version']}"
            if r.get("release_url") != f"https://github.com/BKLockly/ShallowEnd-Plugins/releases/tag/{tag}":
                fail(f"{name}: registry release_url does not match tag {tag}")

        # 6. forbidden files (skip gitignored paths, e.g. zig's local zig-pkg/ cache)
        for bad in FORBIDDEN:
            p = os.path.join(d, bad)
            if not os.path.exists(p):
                continue
            r = subprocess.run(
                ["git", "check-ignore", "-q", os.path.relpath(p, ROOT)],
                cwd=ROOT, capture_output=True,
            )
            if r.returncode != 0:
                fail(f"{name}: forbidden file/dir present: {bad}")

    if len(tokota_refs) > 1:
        fail(f"plugins pin different tokota versions: {tokota_refs}")

    if failures:
        print(f"\n{failures} problem(s) found")
        return 1
    print(f"OK: {len(plugin_dirs)} plugins consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
