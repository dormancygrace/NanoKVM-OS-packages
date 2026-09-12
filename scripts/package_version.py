#!/usr/bin/env python3
"""Render one canonical APK version from explicit recipe version fields."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

# Match the version alphabet accepted by apk-tools v3.  Ordering is still
# delegated to apk itself; this only prevents a recipe from creating a name
# that the native parser cannot read.
PKGVER_RE = re.compile(r"^[0-9][0-9A-Za-z._-]*$")


def canonical_version(manifest: dict) -> str:
    source_version = manifest.get("source_version")
    if not isinstance(source_version, str) or not source_version or any(
        ord(char) < 0x20 or ord(char) == 0x7F for char in source_version
    ):
        raise ValueError("source_version must be a non-empty printable string")
    pkgver = manifest.get("pkgver")
    if not isinstance(pkgver, str) or not PKGVER_RE.fullmatch(pkgver):
        raise ValueError("pkgver must be an APK-compatible version component")
    pkgrel = manifest.get("pkgrel")
    if type(pkgrel) is not int or pkgrel < 0:
        raise ValueError("pkgrel must be a non-negative integer")
    return f"{pkgver}-r{pkgrel}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        print(canonical_version(manifest))
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        raise SystemExit(f"package-version: {exc}") from exc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
