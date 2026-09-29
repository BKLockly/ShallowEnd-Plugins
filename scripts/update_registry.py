#!/usr/bin/env python3
"""
Update marketplace registry.json with a newly released plugin's artifacts.

Usage (called by CI, one invocation per released plugin):
    python3 scripts/update_registry.py \
        --name docker_detect \
        --version 3.0.1 \
        --repo-url https://github.com/BKLockly/ShallowEnd-Plugins \
        --release-url https://github.com/BKLockly/ShallowEnd-Plugins/releases/tag/docker_detect-v3.0.1 \
        --artifacts-dir plugins/docker_detect/dist \
        --plugin-json plugins/docker_detect/plugin.json

Reads plugin metadata from plugin.json, scans artifacts-dir for .node files,
computes SHA256 + size, then merges the entry into registry.json (repo root).
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys


def parse_platform(filename: str) -> str:
    """Extract platform identifier from artifact filename."""
    # e.g. "docker_detect-linux-x64.node" -> "linux-x64"
    match = re.search(
        r"-(linux-x64|linux-arm64|darwin-x64|darwin-arm64|win32-x64)\.node$", filename
    )
    if match:
        return match.group(1)
    raise ValueError(f"Cannot parse platform from filename: {filename}")


def load_registry(path: str) -> dict:
    """Load existing registry.json, or return the default structure."""
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {"marketplace_version": 1, "updated_at": "", "plugins": []}


def scan_artifacts(artifacts_dir: str, release_url: str) -> dict:
    """Scan artifacts dir for .node files, keyed by platform."""
    artifacts = {}
    for fname in sorted(os.listdir(artifacts_dir)):
        if not (fname.endswith(".node") or fname.endswith(".js")):
            continue
        filepath = os.path.join(artifacts_dir, fname)
        with open(filepath, "rb") as f:
            sha256 = hashlib.sha256(f.read()).hexdigest()
        if fname.endswith(".js"):
            platform = "any"  # js 插件平台无关
        else:
            platform = parse_platform(fname)
        tag = release_url.rstrip("/").rsplit("/", 1)[-1]
        base = release_url.rstrip("/").replace(f"/releases/tag/{tag}", "")
        artifacts[platform] = {
            "filename": fname,
            "url": f"{base}/releases/download/{tag}/{fname}",
            "sha256": sha256,
            "size": os.path.getsize(filepath),
        }
    return artifacts


def main():
    parser = argparse.ArgumentParser(description="Update plugin marketplace registry")
    parser.add_argument("--name", required=True, help="Plugin name (e.g. docker_detect)")
    parser.add_argument("--version", required=True, help="Plugin version (e.g. 3.0.0)")
    parser.add_argument("--repo-url", required=True, help="Plugin source repository URL")
    parser.add_argument("--release-url", required=True, help="Release page URL")
    parser.add_argument("--artifacts-dir", default="./dist", help="Directory with built .node files")
    parser.add_argument("--plugin-json", default="plugin.json", help="Path to plugin.json")
    parser.add_argument("--registry-path", default="registry.json", help="Path to registry.json")
    args = parser.parse_args()

    with open(args.plugin_json) as f:
        plugin_meta = json.load(f)
    registry = load_registry(args.registry_path)

    artifacts = scan_artifacts(args.artifacts_dir, args.release_url)
    if not artifacts:
        print(f"ERROR: no .node/.js artifacts found in {args.artifacts_dir}")
        sys.exit(1)

    print(f"Found {len(artifacts)} platform variants for {args.name} v{args.version}:")
    for plat, art in sorted(artifacts.items()):
        print(f"  {plat}: {art['filename']} ({art['size']} bytes, sha256 {art['sha256'][:16]}...)")

    entry = {
        "name": args.name,
        "label": plugin_meta.get("label", args.name),
        "description": plugin_meta.get("description", ""),
        "version": args.version,
        "author": plugin_meta.get("author", ""),
        "risk_level": plugin_meta.get("risk_level", "low"),
        "type": plugin_meta.get("type", "native"),
        "repo_url": args.repo_url,
        "release_url": args.release_url,
        "methods": plugin_meta.get("methods", []),
        "artifacts": artifacts,
    }

    registry["plugins"] = [p for p in registry["plugins"] if p["name"] != args.name]
    registry["plugins"].append(entry)
    registry["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )

    with open(args.registry_path, "w") as f:
        json.dump(registry, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"\nRegistry updated: {args.name} v{args.version} (total {len(registry['plugins'])} plugins)")


if __name__ == "__main__":
    main()
