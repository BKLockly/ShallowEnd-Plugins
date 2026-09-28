# AGENTS.md — plugin-sensitive-search

Zig 0.16.0 NAPI native addon for Node.js (via tokota framework). Scans Linux filesystems
for sensitive files. Part of the ShallowEnd plugin ecosystem.

## Build & commands

```sh
zig build test              # Run Zig unit tests (src/test.zig)
make build-all              # Cross-compile .node for all 5 platforms → dist/
zig build                   # Dev build, produces sensitive_search.node in repo root
node test.js                # Manual Node.js smoke test (requires .node file first)
```

## Source layout

| File | Responsibility |
|---|---|
| `src/root.zig` | NAPI entrypoint, `tokota.exportModule(@This())`, conditionally imports scanner |
| `src/types.zig` | Shared: patterns, search_paths, config constants, `getFileType()`, `log()` helper |
| `src/scanner.zig` | **Linux-only** (comptime guarded). `scan()`, `walkDir()`, `matchFile()` — uses `std.c` POSIX APIs |
| `src/test.zig` | Unit tests importing from `types.zig`. No tokota dependency, cross-platform. |

## Key facts

- **Platform handling:** `scanner.zig` is only compiled on Linux via `if (builtin.os.tag == .linux) @import("scanner.zig")`. Non-Linux targets (macOS, Windows) get a no-op stub. The `search()` export still works on all platforms, returning an error log on non-Linux.
- **Dependency:** `tokota` is vendored at repo-root `shared/zig-pkg/` (`../../shared/zig-pkg/` from the plugin dir) — no network fetch needed.
- **Output:** `.node` file in repo root (`sensitive_search.node`). `make build-all` copies to `dist/` with platform suffixes.
- **CI:** GitHub Actions (`.github/workflows/build.yml`) — triggered on push to `main`; idempotent tag-based release, updates `registry.json`.
- **Clean:** `rm -f sensitive_search.node` after dev build.
- **Search logic:** Dual-mode — filename pattern matching + content scanning (first 4KB). Content scan detects `-----BEGIN`, `PRIVATE KEY`, `PASSWORD=`, `SECRET_KEY`, `ACCESS_KEY`, `API_KEY`, `TOKEN=`, SSH keys, DB connection strings.
- **Search paths:** `/etc /home /root /var /app /opt /srv` (removed `/tmp` — too noisy).
