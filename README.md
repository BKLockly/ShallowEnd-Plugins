# ShallowEnd-Plugins

Official plugin monorepo for the [ShallowEnd](https://github.com/BKLockly/ShallowEnd) marketplace. Plugins are written in Zig + [Tokota](https://github.com/kofi-q/tokota) and compiled to Node.js native addons (`.node`, N-API) — version-independent across Node runtimes. The marketplace index `registry.json` lives at the repo root and is maintained by the CI bot.

This repository is fully decoupled from the ShallowEnd main app: the app only points its `plugin_marketplace_url` setting at this repo's `registry.json`.

## Layout

```
ShallowEnd-Plugins/
├── .github/workflows/
│   └── build.yml             ← the only CI: build / release / index update
├── registry.json             ← marketplace index (bot-maintained, do not hand-edit)
├── scripts/
│   ├── scaffold.py           ← new-plugin scaffolding generator
│   └── update_registry.py    ← registry.json updater (invoked by CI)
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
python3 scripts/scaffold.py port_scan --label "Port Scan" --desc "TCP port scanner" --risk medium
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
