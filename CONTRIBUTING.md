# Contributing

Thanks for your interest in contributing plugins to ShallowEnd-Plugins.

## Prerequisites

- [Zig](https://ziglang.org) **0.16.0** (the CI pins this version)
- [just](https://github.com/casey/just) — repo task runner
- Python 3.10+ (scaffolding and consistency checks)
- Node.js (optional, for `just node-test` integration smoke tests)

## Quick Start

```sh
# scaffold a new plugin (creates plugins/<name>/, runs zig build test)
just new port_scan --label "Port Scan" --desc "TCP port scanner" --risk medium

cd plugins/port_scan
# implement src/root.zig, fill in plugin.json methods
```

## The Rules

The full development contract lives in [AGENTS.md](AGENTS.md) — read it before
your first PR. The short version:

1. Directory name = `plugin.json` `name`, snake_case.
2. `plugin.json` `version` (strict semver) is the single source of truth; CI
   releases automatically when it changes.
3. Dependencies are pinned via upstream URL + content hash — never vendored.
4. `registry.json` is bot-owned; never hand-edit it.
5. Unit tests in `src/test.zig` must pass without a Node runtime.

## Before Opening a PR

```sh
just pre-push   # fmt-check + consistency check + full test run
```

CI runs the same gates (`zig fmt --check` → `check_consistency.py` →
`zig build test`) and blocks the release on failure.

## Releases

You don't cut releases manually. Bump `version` in `plugin.json`, push to
`main`, and the CI will tag `<name>-v<version>`, publish the release with
artifacts for linux-x64/arm64, and update `registry.json`.
