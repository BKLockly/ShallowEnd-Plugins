# Third-Party Components

This repository vendors and redistributes third-party code. Their original licenses apply.

## AgentScan (vendored in `plugins/agentscan/agentscan/`)

- Upstream: https://github.com/7anX/AgentScan
- License: MIT, (c) 2026 7anX — upstream `LICENSE` preserved in `plugins/agentscan/agentscan/LICENSE`
- Used by: `agentscan` plugin — the upstream Go binary is built from the vendored source at plugin build time (`CGO_ENABLED=0` static, linux amd64/arm64), gzip-compressed and embedded into the `.node` addon; a thin Zig shim extracts it to a temp dir and executes it
- Upstream commit: `2589c3093d080a8a92fe068822859b1780a26901` (2026-08-01)
- Modifications: build/community files (`.goreleaser.yml`, `build.sh`, `build.ps1`, `.golangci.yml`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `docs/`, `README_en.md`) omitted; Go source, `dicts/`, `go.mod`/`go.sum` unmodified

## bof-launcher (vendored in `plugins/bof/bof-launcher/`)

- Upstream: https://github.com/The-Z-Labs/bof-launcher
- License: BSD-3-Clause, (c) 2022-2026 Z-Labs (https://z-labs.eu) — full text upstream `LICENSE.md`
- Used by: `bof` plugin, statically linked (`plugins/bof/lib/<platform>/libbof_launcher_*.a`)
- Modifications: trimmed to `src/` for source browsing; prebuilt static libraries are placed under `plugins/bof/lib/`.

## stb (vendored headers in `plugins/bof/bof-launcher/src/`)

- Upstream: https://github.com/nothings/stb
- License: Public Domain / MIT (dual, per stb README)
- Files: `stb_sprintf.h`

## linux_exploit_suggester (in `plugins/linux_exploit_suggester/`)

- Knowledge base (CVE records) derives from linux-exploit-suggester.sh (The-Z-Labs, GPL-3.0); upstream `LICENSE` (GPL-3.0) and `CHANGELOG` preserved in `plugins/linux_exploit_suggester/`
- Matching logic is an original Zig implementation
- Note: the CVE knowledge base is GPL-3.0-derived — treat `plugins/linux_exploit_suggester/` as GPL-3.0 despite the repository-wide MIT license.

## tokota (fetched via the zig package manager)

- Upstream: https://github.com/kofi-q/tokota
- License: MIT, (c) Nana Kofi Ohene-Adu — see upstream `LICENSE`
- Used as: Zig → Node.js N-API binding toolkit, shared by all plugins
- Pinned in every `build.zig.zon` via immutable commit-tarball URL + content hash (`f8b15cf72d649229f317b9e588bb4a1622188da8`, Zig 0.16.x compatible line)

## zig `base` package (transitive dependency of tokota)

- Upstream: https://github.com/kofi-q/base-z (branch `zig-0.16`)
- License: MIT (see upstream `LICENSE`)
- Resolved transitively by the zig package manager, pinned by content hash

## mysql_driver (in `plugins/mysql_driver/`)

- Bundles [mysql2](https://github.com/sidorares/node-mysql2) (MIT) and its npm dependency tree (MIT / ISC / Apache-2.0), built with [esbuild](https://github.com/evanw/esbuild) (MIT)
- The bundle is a plain CJS build (platform-independent), loaded in-memory by the ShallowEnd payload; upstream licenses apply to the bundled code

## pg_driver (in `plugins/pg_driver/`)

- Bundles [pg](https://github.com/brianc/node-postgres) (MIT) and its npm dependency tree (MIT / ISC), built with [esbuild](https://github.com/evanw/esbuild) (MIT)
- The bundle is a plain CJS build (platform-independent), loaded in-memory by the ShallowEnd payload; upstream licenses apply to the bundled code
