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

## tokota (vendored in `shared/zig-pkg/tokota-0.1.0-*/`)

- Upstream: https://github.com/kofi-q/tokota
- License: MIT, (c) Nana Kofi Ohene-Adu — see bundled `LICENSE`
- Used as: Zig → Node.js N-API binding toolkit, shared by all plugins

## zig `base` package (vendored in `shared/zig-pkg/base-0.1.0-*/`)

- Upstream: ziglang stdlib-derived utility sources shipped with the Zig distribution
- License: MIT (see bundled `src/autodoc/LICENSE`)
- Used as: build-time dependency of the vendored tokota package
