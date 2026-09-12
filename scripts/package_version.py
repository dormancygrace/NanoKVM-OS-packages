#!/usr/bin/env python3
"""Render and validate one canonical APK version from recipe fields."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

# This is a preliminary shape check.  apk-tools remains authoritative for the
# complete grammar and is called before a recipe is accepted for packaging.
PKGVER_RE = re.compile(r"^[0-9][0-9A-Za-z._-]*$")


def validate_apk_version(version: str, apk: str | Path) -> None:
    tool = Path(apk)
    if not tool.is_file() or not tool.stat().st_mode & 0o111:
        raise ValueError(f"native apk executable is missing: {tool}")
    try:
        result = subprocess.run(
            [str(tool), "version", "--check", version],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise ValueError(f"cannot execute native apk: {tool}: {exc}") from exc
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        suffix = f": {detail}" if detail else ""
        raise ValueError(f"apk rejected version {version!r}{suffix}")


def canonical_version(manifest: dict, apk: str | Path | None = None) -> str:
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
    version = f"{pkgver}-r{pkgrel}"
    if apk is not None:
        validate_apk_version(version, apk)
    return version


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--apk", required=True, type=Path,
                        help="native apk-tools executable used for final version validation")
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        print(canonical_version(manifest, args.apk))
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        raise SystemExit(f"package-version: {exc}") from exc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
