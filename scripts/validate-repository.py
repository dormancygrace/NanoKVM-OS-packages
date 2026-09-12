#!/usr/bin/env python3
"""Validate NanoKVM addon recipes before apk package generation.

This validator uses only the Python standard library around one supplied
native apk-tools executable.  It checks the package-owned namespace,
declarative service syntax and exact capability contract, then asks apk-tools
to validate every complete package version.  Archive signatures and
dependency resolution are checked by the build/self-test scripts after this
pass.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from package_version import PKGVER_RE, canonical_version

ID_RE = re.compile(r"^[a-z0-9][a-z0-9+_.-]*$")
VERSION_RE = re.compile(r"^[0-9][0-9A-Za-z._-]*-r[0-9]+$")
BASE_RE = re.compile(r"^nkos-base-abi=[0-9]+\.[0-9]+\.[0-9]+$")
API_RE = re.compile(r"^nkos-server-api=[0-9]+$")
FEATURE_RE = re.compile(r"^nkos-feature-[a-z0-9][a-z0-9-]*=[0-9]+$")
SERVICE_COMMAND_RE = re.compile(r"^/opt/nkos/addons/[a-z0-9][a-z0-9+_.-]*/[^;&|<>`$()\\']+$")
SCRIPT_SUFFIXES = (".pre-install", ".post-install", ".pre-upgrade", ".post-upgrade", ".trigger")


class InvalidRecipe(ValueError):
    pass


def fail(message: str) -> None:
    raise InvalidRecipe(message)


def safe_relative(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.startswith("/"):
        fail(f"{label} must be a relative path")
    path = Path(value)
    if any(part in ("", ".", "..") for part in path.parts):
        fail(f"{label} contains an unsafe path: {value}")
    return value


def string_field(manifest: dict, key: str) -> str:
    value = manifest.get(key)
    if not isinstance(value, str) or not value:
        fail(f"{key} is required and must be a string")
    return value


def validate_recipe(recipe: Path, base_abi: str | None, apk: Path) -> dict:
    manifest_path = recipe / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        fail(f"missing manifest: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read {manifest_path}: {exc}")
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        fail(f"{manifest_path}: schema must be 1")
    recipe_id = string_field(manifest, "id")
    package = string_field(manifest, "package")
    if "version" in manifest:
        fail(f"{package}: version is generated from pkgver/pkgrel")
    source_version = string_field(manifest, "source_version")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in source_version):
        fail(f"{package}: source_version contains a control character")
    try:
        version = canonical_version(manifest, apk)
    except ValueError as exc:
        fail(f"{package}: {exc}")
    if not ID_RE.fullmatch(recipe_id):
        fail(f"invalid addon id: {recipe_id}")
    if package != f"nkos-addon-{recipe_id}":
        fail(f"package must be nkos-addon-{recipe_id}")
    if not VERSION_RE.fullmatch(version):
        fail(f"invalid package version: {version}")
    if manifest.get("arch") != "riscv64":
        fail(f"{package}: arch must be riscv64")
    if not string_field(manifest, "description") or not string_field(manifest, "license"):
        fail(f"{package}: description and license are required")
    provider = string_field(manifest, "base_abi_provider")
    if provider != "nkos-base-abi":
        fail(f"{package}: base_abi_provider must be nkos-base-abi")
    api = string_field(manifest, "server_api")
    if not API_RE.fullmatch(api) or api != "nkos-server-api=1":
        fail(f"{package}: server_api must be nkos-server-api=1")
    features = manifest.get("features")
    if not isinstance(features, list) or not features or len(set(features)) != len(features):
        fail(f"{package}: features must be a non-empty unique list")
    if any(not isinstance(feature, str) or not FEATURE_RE.fullmatch(feature) for feature in features):
        fail(f"{package}: malformed feature capability")
    if base_abi is not None:
        if not BASE_RE.fullmatch(base_abi):
            fail(f"invalid exact base ABI: {base_abi}")
    config = string_field(manifest, "config")
    data = string_field(manifest, "data")
    if config != f"/etc/kvm/{recipe_id}" or data != f"/data/{recipe_id}":
        fail(f"{package}: config/data must use host-managed addon paths")
    preserve = manifest.get("preserve")
    if preserve != ["config", "data"] and not (isinstance(preserve, list) and set(preserve) == {"config", "data"}):
        fail(f"{package}: preserve must contain config and data")
    for forbidden in ("scripts", "triggers", "install_if", "replaces"):
        if forbidden in manifest:
            fail(f"{package}: {forbidden} metadata is forbidden")

    payload = manifest.get("payload_files")
    generated = manifest.get("generated_files", [])
    if not isinstance(payload, list) or len(set(payload)) != len(payload):
        fail(f"{package}: payload_files must be a unique list")
    if not isinstance(generated, list) or len(set(generated)) != len(generated):
        fail(f"{package}: generated_files must be a unique list")
    listed: set[str] = set()
    for value in payload:
        value = safe_relative(value, f"{package} payload")
        if not value.startswith(f"addons/{recipe_id}/"):
            fail(f"{package}: payload leaves addons/{recipe_id}/: {value}")
        if any(value.endswith(suffix) for suffix in SCRIPT_SUFFIXES):
            fail(f"{package}: package script path is forbidden: {value}")
        listed.add(value)
    for value in generated:
        value = safe_relative(value, f"{package} generated payload")
        if value not in listed:
            fail(f"{package}: generated file is not in payload_files: {value}")

    files_root = recipe / "files"
    if not files_root.is_dir() or files_root.is_symlink():
        fail(f"{package}: files directory is missing")
    actual: set[str] = set()
    for item in files_root.rglob("*"):
        relative = item.relative_to(files_root).as_posix()
        if item.is_symlink():
            fail(f"{package}: symlink in payload source: {relative}")
        if item.is_file():
            if any(relative.endswith(suffix) for suffix in SCRIPT_SUFFIXES):
                fail(f"{package}: package script source is forbidden: {relative}")
            actual.add(relative)
    for relative in actual:
        if relative not in listed:
            fail(f"{package}: unlisted payload file: {relative}")
    for relative in listed - set(generated):
        if not (files_root / relative).is_file():
            fail(f"{package}: declared payload file is missing: {relative}")

    services = manifest.get("services")
    if not isinstance(services, list):
        fail(f"{package}: services must be a list")
    service_names: set[str] = set()
    for service in services:
        if not isinstance(service, dict):
            fail(f"{package}: malformed service descriptor")
        name = service.get("name")
        command = service.get("command")
        if not isinstance(name, str) or not ID_RE.fullmatch(name) or name in service_names:
            fail(f"{package}: invalid or duplicate service name")
        if not isinstance(command, str) or not SERVICE_COMMAND_RE.fullmatch(command):
            fail(f"{package}: service command is outside the addon namespace")
        if not command.startswith(f"/opt/nkos/addons/{recipe_id}/"):
            fail(f"{package}: service command names another addon")
        if service.get("default_enabled") not in (True, False):
            fail(f"{package}: default_enabled must be boolean")
        if service.get("restart") not in ("never", "on-update", "always"):
            fail(f"{package}: restart policy is invalid")
        service_names.add(name)

    build_script = recipe / "build.sh"
    if not build_script.is_file() or build_script.is_symlink():
        fail(f"{package}: build.sh is required")
    return {
        "schema": 1,
        "id": recipe_id,
        "package": package,
        "source_version": source_version,
        "pkgver": manifest["pkgver"],
        "pkgrel": manifest["pkgrel"],
        "version": version,
        "arch": "riscv64",
        "description": manifest["description"],
        "license": manifest["license"],
        "maintainer": manifest.get("maintainer", "NanoKVM OS maintainers"),
        "base_abi_provider": provider,
        "server_api": api,
        "features": features,
        "config": config,
        "data": data,
        "services": services,
        "preserve": ["config", "data"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--base-abi")
    parser.add_argument("--apk", type=Path, required=True,
                        help="native apk-tools executable for authoritative version validation")
    args = parser.parse_args()
    if not args.apk.is_file() or not args.apk.stat().st_mode & 0o111:
        print(f"validate-repository: executable --apk is required: {args.apk}", file=sys.stderr)
        return 2
    recipes = sorted(path for path in (args.root / "recipes").iterdir() if path.is_dir())
    if not recipes:
        print("validate-repository: no recipes found", file=sys.stderr)
        return 1
    seen: set[tuple[str, str]] = set()
    try:
        for recipe in recipes:
            descriptor = validate_recipe(recipe, args.base_abi, args.apk)
            key = (descriptor["package"], descriptor["version"])
            if key in seen:
                fail(f"duplicate package/version: {key[0]} {key[1]}")
            seen.add(key)
    except InvalidRecipe as exc:
        print(f"validate-repository: {exc}", file=sys.stderr)
        return 1
    print(f"validated {len(seen)} NanoKVM addon recipe(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
