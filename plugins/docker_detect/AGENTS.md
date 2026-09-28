# docker_detect — AGENTS.md

This is a **Zig** project (Node.js native addon via `tokota`), not Go. It builds a `.node` binary that detects Docker containers from inside a guest OS.

## Commands

| Command | What |
|---|---|
| `zig build` | Build `docker.node` for host target |
| `zig build test` | Run unit tests (standalone, no addon loaded) |
| `node test.js` | Integration test — requires `docker.node` to exist |
| `make build-all` | Cross-compile for all platforms → `dist/` |
| `python3 ../../scripts/update_registry.py ...` | Invoked by CI to register a release in the marketplace index |

## Architecture

- **Entrypoint:** `src/root.zig` — exports `detect()` via `comptime { tokota.exportModule(@This()); }`
- **Node API:** `require("./docker.node").isDocker()` returns `{ logs: string, confidence: number }`
- **Detection only works on Linux** — non-Linux returns confidence=0 (with macOS-specific debug hints)
- **Confidence scoring:** `/.dockerenv` (+40), cgroup (+20–35), mountinfo (+10–15), env vars (+10–35); ≥70 = "very likely"
- **Tests are standalone** (no tokota dependency): `src/test.zig` tests a `formatInt` utility

## Build quirks

- Output file `docker.node` lands in **repo root** (not `zig-out/`) — `build.zig` sets `output_dir: .{ .custom = "../" }`
- Requires `link_libc = true` (set in `build.zig`)
- Dependency `tokota` declared in `build.zig.zon` as upstream URL + content hash (zig package manager)
- Minimum Zig version: `0.16.0`

## CI / Release

- `.github/workflows/build.yml` — triggered on push to `main` (or manual dispatch)
- Idempotent: releases only when `<name>-v<version>` tag doesn't exist yet
- `gh release create` uploads artifacts, then the bot merges the entry into `registry.json`
