# Third-Party Components

This repository vendors and redistributes third-party code. Their original licenses apply.

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
