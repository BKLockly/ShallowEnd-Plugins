# Security Policy

## Supported Scope

This repository ships offensive-security plugins for the ShallowEnd platform
(Node.js native addons executed on target machines). The plugins themselves are
**not** the attack surface of this project — they are payloads.

## Reporting a Vulnerability

For vulnerabilities in the *build system, CI, or scaffolding tooling* of this
repository (e.g. dependency pinning bypass, CI injection, artifact tampering),
please use **GitHub's private vulnerability reporting** on this repository.
Do not open a public issue.

## Responsible Use

These plugins are provided for **authorized security testing and research
only**. Running them against systems you do not own or do not have explicit
written permission to test is illegal in most jurisdictions. The maintainers
accept no liability for misuse.

## Dependency Integrity

All build-time dependencies are pinned by immutable upstream archive URL plus
content hash (`build.zig.zon`). Release artifacts are checksummed (SHA-256) in
`registry.json` and verified by the client on install. Report any deviation
from this model as a vulnerability.
