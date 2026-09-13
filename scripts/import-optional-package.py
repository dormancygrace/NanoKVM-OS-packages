#!/usr/bin/env python3
"""Consume the hash-recorded optional binary input from the firmware build."""
import hashlib, json, os, shutil, sys
from pathlib import Path
id, stage = sys.argv[1], Path(sys.argv[2])
value = os.environ.get("NKOS_OPTIONAL_INPUT")
if not value:
    raise SystemExit("NKOS_OPTIONAL_INPUT is required; run export-optional-packages.py on the source-built O2 firmware output")
root = Path(value).resolve()
index = json.loads((root / "input.json").read_text())
manifest = json.loads((Path(__file__).resolve().parents[1] / "recipes" / ("nkos-addon-"+id) / "manifest.json").read_text())
if index.get("schema") != 1 or index["packages"][id]["source_version"] != manifest["source_version"]:
    raise SystemExit("Optional input version does not match recipe")
source = root / id
expected = {name: digest for name,digest in index["files"].items() if name.startswith(id+"/")}
actual = {}
for path in source.rglob("*"):
    if path.is_symlink(): raise SystemExit("Symlink in optional input")
    if path.is_file(): actual[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
if not expected or actual != expected:
    raise SystemExit("Optional input content/hash mismatch")
shutil.copytree(source,stage/"addons"/id,dirs_exist_ok=True)
