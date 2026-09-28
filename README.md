# ShallowEnd-Plugins

[![Build and Release](https://github.com/BKLockly/ShallowEnd-Plugins/actions/workflows/build.yml/badge.svg)](https://github.com/BKLockly/ShallowEnd-Plugins/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Official plugin monorepo for the [ShallowEnd](https://github.com/BKLockly/ShallowEnd) marketplace. Plugins are written in Zig + [Tokota](https://github.com/kofi-q/tokota) and compiled to Node.js native addons (`.node`, N-API) — version-independent across Node runtimes. The marketplace index `registry.json` lives at the repo root and is maintained by the CI bot.

This repository is fully decoupled from the ShallowEnd main app: the app only points its `plugin_marketplace_url` setting at this repo's `registry.json`.

## Layout

```
ShallowEnd-Plugins/
├── .github/workflows/
│   └── build.yml             ← the only CI: build / release / index update
├── registry.json             ← marketplace index (bot-maintained, do not hand-edit)
├── Justfile                  ← repo-level task runner (just test / check / new / ...)
├── scripts/
│   ├── scaffold.py           ← new-plugin scaffolding generator
│   ├── check_consistency.py  ← consistency checks (CI gate + local `just check`)
│   ├── update_registry.py    ← registry.json updater (invoked by CI)
│   └── update_tokota.py      ← bump the pinned tokota dependency
├── plugins/                  ← one directory per plugin (deps resolved by the zig package manager)
└── plugins/                  ← one directory per plugin, dir name = plugin name
```

## Plugins

| Plugin | Version | Description | Risk |
|--------|---------|-------------|------|
| bof | 0.2.0 | Load and execute Beacon Object Files (BOF), musl static build | high |
| docker_detect | 3.0.1 | Detect Docker container environments | low |
| file_compress | 0.2.0 | Gzip-compress a single file in pure Zig | low |
| file_decompress | 0.2.1 | Decompress .gz files in pure Zig | low |
| hello | 0.4.1 | Scaffold example plugin | low |
| linux_exploit_suggester | 1.3 | Suggest kernel LPE exploits matching the target kernel | low |
| sensitive_search | 0.14.2 | Search the target filesystem for sensitive files/credentials | medium |
| agentscan | 0.1.0 | Intranet MCP / A2A / LLM exposure scan (embedded AgentScan engine) | medium |

## Acknowledgements

ShallowEnd-Plugins builds on these open-source projects — thank you! Full license details and modification notes live in [THIRD_PARTY.md](THIRD_PARTY.md).

| Project | License | Used by |
|---------|---------|---------|
| [AgentScan](https://github.com/7anX/AgentScan) | MIT © 2026 7anX | `agentscan` plugin (embedded scan engine, vendored) |
| [bof-launcher](https://github.com/The-Z-Labs/bof-launcher) | BSD-3-Clause © 2022-2026 Z-Labs | `bof` plugin (statically linked, vendored) |
| [Tokota](https://github.com/kofi-q/tokota) | MIT © Nana Kofi Ohene-Adu | Zig → Node.js N-API toolkit, all plugins |
| [base-z](https://github.com/kofi-q/base-z) | MIT | transitive dependency of Tokota |
| [stb](https://github.com/nothings/stb) | Public Domain / MIT | vendored headers inside bof-launcher |
| [linux-exploit-suggester](https://github.com/mzet-/linux-exploit-suggester) | GPL-3.0 | CVE knowledge base of `linux_exploit_suggester` |

## Platform Matrix

| Platform | ID | Zig target | Built |
|----------|----|-----------|-------|
| Linux x86_64 | `linux-x64` | `x86_64-linux-gnu` | ✅ |
| Linux ARM64 | `linux-arm64` | `aarch64-linux-gnu` | ✅ |
| Windows x64 | `win32-x64` | `x86_64-windows-gnu` | ❌ |
| macOS | `darwin-*` | — | ❌ |

Rationale: Linux targets first; ARM Linux (cloud/containers) is free to keep. Windows has no test capacity and near-zero Node.js targets in scope; macOS builds are a local `zig build -Dtarget=...` smoke away if ever needed. **bof exception**: musl libc (`*-linux-musl`) for static linking of bof-launcher.

## Release Flow (fully automated)

```
Edit plugins/<name>/plugin.json "version"
        │
        ▼ push to main
CI: scan plugins/*, compare version against existing tags <name>-v<version>
        │
        ├─ tag exists    → skip (idempotent, re-push safe)
        └─ tag missing   → make build-all (both platforms)
                           → gh release create <tag> + upload dist/*.node
                           → update_registry.py merges entry into registry.json
                           → bot commit "ci: update registry ... [skip ci]"
```

- Tag format: `<name>-v<version>`, e.g. `docker_detect-v3.0.1`
- Force a rebuild: bump the version (dispatch with an unchanged version still skips)

## Registry Schema

```json
{
  "marketplace_version": 1,
  "updated_at": "2026-09-08T00:00:00Z",
  "plugins": [
    {
      "name": "docker_detect",
      "label": "Docker Environment Detection",
      "description": "...",
      "version": "3.0.1",
      "author": "BKLockly",
      "risk_level": "low",
      "repo_url": "https://github.com/BKLockly/ShallowEnd-Plugins",
      "release_url": "https://github.com/BKLockly/ShallowEnd-Plugins/releases/tag/docker_detect-v3.0.1",
      "methods": [ "..." ],
      "artifacts": {
        "linux-x64":   { "filename": "...", "url": "...", "sha256": "...", "size": 123 },
        "linux-arm64": { "filename": "...", "url": "...", "sha256": "...", "size": 123 }
      }
    }
  ]
}
```

The client validates artifacts by `sha256` on install and selects the artifact matching the target architecture at load time.

## Add a Plugin

```bash
just new port_scan --label "Port Scan" --desc "TCP port scanner" --risk medium
cd plugins/port_scan
zig build test          # unit tests
make build-all          # local smoke build (CI artifacts are canonical)
# implement src/root.zig, fill plugin.json methods
# bump version → git push → CI releases automatically
```

## Rules (enforced by convention + CI)

1. **Directory name = `plugin.json` `name`**, snake_case.
2. **`plugin.json` `version` is the single source of truth** for releases.
3. **Artifact naming**: `<name>-linux-x64.node` / `<name>-linux-arm64.node`.
4. **Forbidden** inside plugin dirs: per-plugin CI, `update_registry.py` copies, vendored dependency copies.
5. **tokota declared via the zig package manager**: `.url` pinned to an immutable upstream commit tarball + `.hash` content verification, identical across all plugins.
6. **No vendored dependencies**: build deps resolve from upstream via URL + hash pinning; zig materializes them locally under `zig-pkg/` (gitignored).
7. **Every plugin must pass `zig build test`**: unit tests in `src/test.zig`, no tokota import (no Node runtime in CI); Node-dependent integration goes in `test.js`.
8. **Never hand-edit `registry.json`** — bot-owned.

## Local Development

Repo-level tasks run through [just](https://github.com/casey/just) (see `Justfile`):

```bash
just test            # unit tests, all plugins (or: just test bof hello)
just build-all       # canonical artifacts for every plugin → dist/
just check           # repo consistency checks
just fmt / fmt-check # formatting (third-party sources excluded)
just pre-push        # fmt-check + check + test
just new <name> ...  # scaffold a new plugin
just update-tokota <tarball-or-url>  # bump the pinned tokota version
just clean
```

Per-plugin builds still go through each plugin's `Makefile`:

```bash
cd plugins/<name>
make build-all   # both platforms → dist/
make test        # zig build test (no tokota dependency)
make node-test   # node test.js (needs host-platform .node from zig build)
make clean
```

Note: cross-compiled artifacts (e.g. Linux binaries built on macOS) are smoke-test only; **CI artifacts are canonical**.

## Plugin Development Notes (Tokota)

Entry `src/root.zig`:

```zig
const std = @import("std");
const tokota = @import("tokota");

comptime {
    tokota.exportModule(@This());   // export module
}

pub fn myMethod(call: tokota.Call) ![]const u8 {
    const args = try call.argsAs(.{tokota.Val});
    const params = args[0].object(call.env);   // always accept one JS object

    const num = try params.getT("key_num", f64);
    const flag = try params.getT("key_bool", bool);
    const opt = try params.getT("key_opt", ?f64) orelse 0;

    // Strings cannot use getT(_, []const u8) (tokota 0.1.0 cannot infer the
    // conversion) — take the Val and convert explicitly with stringAlloc:
    var str: []const u8 = "default";
    if (params.get("key_str")) |val| {
        if (!try val.isNullOrUndefined(call.env)) {
            str = try val.stringAlloc(call.env, std.heap.c_allocator);
        }
    } else |_| {}

    return "result string";
}
```

- Every method takes **one JS object** (frontend calls `module[method](params)`); read fields by name.
- Numbers/bools via `getT`; strings must go through `Val.stringAlloc(env, allocator)`.
- Return value is a string rendered by the client plugin log.

### Output Text Contract

Output is split by `\n`; lines matching `^\[(\w+)\]\s*(.*)$` render with a level badge (`[INFO]` / `[WARN]` / `[ERRO]` / `[DEBU]`); other lines render as plain text with `white-space: pre-wrap`. Title lines always carry `[LEVEL]`; detail lines use 4-space indentation without prefix.

```
[INFO] Available information:
    Kernel version: 6.10.14-linuxkit
    Architecture: arm64

[WARN] [CVE-2022-2586] nft_object UAF
    Details: https://...
    Exposure: less probable
```

## License

MIT — see [LICENSE](LICENSE). Third-party components and their licenses are listed in [THIRD_PARTY.md](THIRD_PARTY.md). Note: `plugins/linux_exploit_suggester/` contains a GPL-3.0-derived CVE knowledge base and is licensed GPL-3.0.

## 中文文档

见 [README.zh-CN.md](README.zh-CN.md)。
