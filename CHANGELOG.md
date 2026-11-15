# Changelog

All notable changes to the ShallowEnd-Plugins repository and its tooling.
Per-plugin releases are documented by their GitHub release notes
(<name>-v<version> tags); this file tracks repo-level and tooling changes.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial open-source baseline: 7 plugins (bof, docker_detect, file_compress,
  file_decompress, hello, linux_exploit_suggester, sensitive_search)
- GitHub Actions release pipeline with quality gates
  (zig fmt / consistency / unit tests)
- Root `Justfile` task runner (`just test|build-all|check|new|update-tokota|pre-push`)
- Dependency policy: tokota pinned via immutable upstream URL + content hash
- `scripts/check_consistency.py`, `scripts/update_tokota.py`
- MIT license; third-party notices in `THIRD_PARTY.md`
- js plugin type support (2026-09-29): esbuild CJS bundles for database
  drivers (`mysql_driver`, `pg_driver`, `sqlite_driver`), `any`-platform
  artifacts, `type` field in `plugin.json` / registry schema
- CI: Node smoke test gate — builds each plugin for linux-x64 and runs
  `test.js` with Node 22 (catches napi-layer memory bugs that `zig build test`
  cannot); CI also installs Go 1.25.x for the agentscan embedded engine
- `just verify-linux` (2026-11-15): run `zig build test` natively inside a
  Linux Docker container (node:22-slim + pinned Zig 0.16.0). macOS local
  gates skip semantic analysis of Linux-only branches at comptime, so
  native plugin changes must pass this before push (AGENTS.md pitfall 10)

### Changed

- 2026-11-15: consistency gate allows the "pending release" form — registry
  version behind plugin.json by exactly one release is a WARN (field diff
  skipped; CI rewrites the entry on release); still an ERROR when the
  registry is ahead or otherwise mismatched. AGENTS.md rule 8 updated;
  releases no longer require manual registry pre-edits
- 2026-11-15: engineering pitfalls 10-12 recorded after a 5-run CI burn —
  macOS blind gate for Linux-only branches, GH runner hardened binaries
  (/bin/echo, /bin/sleep replaced by ~11.8MB wrappers that refuse
  memfd-masquerade execution), and CI failure containment discipline

### Fixed

- 2026-11-15: `just test <plugin>` silently ignored its arguments and always
  ran the full suite — just 1.40.0 does not forward arguments to shebang
  recipes (minimal repro: argv empty for `*args` shebang recipes); both
  `test` and `verify-linux` now take parameters via `{{...}}` interpolation
