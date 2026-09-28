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
