#!/usr/bin/env python3
"""Render the immutable addon descriptor embedded in an APK payload."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from package_version import canonical_version


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("base_abi")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    version = canonical_version(manifest)
    descriptor = {
        "schema": 1,
        "id": manifest["id"],
        "package": manifest["package"],
        "source_version": manifest["source_version"],
        "pkgver": manifest["pkgver"],
        "pkgrel": manifest["pkgrel"],
        "version": version,
        "arch": manifest["arch"],
        "base_abi": args.base_abi,
        "server_api": manifest["server_api"],
        "features": manifest["features"],
        "config": manifest["config"],
        "data": manifest["data"],
        "services": manifest["services"],
        "preserve": ["config", "data"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(descriptor, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
