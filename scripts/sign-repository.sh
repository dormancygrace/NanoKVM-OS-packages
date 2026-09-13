#!/bin/sh
# Sign a previously built addon staging tree.  This process may access the
# production key, but it never executes recipe/build.sh or other source build
# hooks.  The staging tree is validated against the checked-out source first.
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
apk=
base_abi=
sign_key=
verify_keys_dir=$repo/keys
staging=
output=
previous=
repository_commit=${REPOSITORY_COMMIT:-}

usage() {
	echo "usage: $0 --apk APK --base-abi nkos-base-abi=X.Y.Z --staging STAGING --sign-key PRIVATE_KEY [--verify-keys-dir DIR] [--previous DIR] --out DIR" >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case $1 in
		--apk) [ "$#" -ge 2 ] || usage; apk=$2; shift 2;;
		--base-abi) [ "$#" -ge 2 ] || usage; base_abi=$2; shift 2;;
		--staging) [ "$#" -ge 2 ] || usage; staging=$2; shift 2;;
		--sign-key) [ "$#" -ge 2 ] || usage; sign_key=$2; shift 2;;
		--verify-keys-dir) [ "$#" -ge 2 ] || usage; verify_keys_dir=$2; shift 2;;
		--previous) [ "$#" -ge 2 ] || usage; previous=$2; shift 2;;
		--out) [ "$#" -ge 2 ] || usage; output=$2; shift 2;;
		*) usage;;
	esac
done

[ -n "$apk" ] && [ -x "$apk" ] || {
	echo 'sign-repository: executable --apk is required' >&2
	exit 2
}
[ "$base_abi" ] || usage
printf '%s\n' "$base_abi" | grep -Eq '^nkos-base-abi=[0-9]+\.[0-9]+\.[0-9]+$' || {
	echo "sign-repository: invalid exact base ABI: $base_abi" >&2
	exit 2
}
[ -n "$staging" ] && [ -d "$staging" ] || {
	echo 'sign-repository: --staging directory is required' >&2
	exit 2
}
[ -f "$sign_key" ] || {
	echo 'sign-repository: signing key is required' >&2
	exit 2
}
[ -d "$verify_keys_dir" ] || {
	echo "sign-repository: public trust key directory is missing: $verify_keys_dir" >&2
	exit 2
}
[ -n "$output" ] || usage
case "$output" in /|.|..|'') echo 'sign-repository: unsafe output path' >&2; exit 2;; esac
[ ! -e "$output" ] || {
	echo "sign-repository: output already exists: $output" >&2
	exit 2
}
if [ -z "$repository_commit" ] && git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
	repository_commit=$(git -C "$repo" rev-parse HEAD)
fi
printf '%s\n' "$repository_commit" | grep -Eq '^[0-9a-fA-F]{40}$' || {
	echo 'sign-repository: a pinned 40-character REPOSITORY_COMMIT is required' >&2
	exit 2
}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
case "$SOURCE_DATE_EPOCH" in ''|*[!0-9]*) echo 'sign-repository: SOURCE_DATE_EPOCH must be an unsigned integer' >&2; exit 2;; esac
export SOURCE_DATE_EPOCH

python3 "$here/validate-repository.py" --root "$repo" --base-abi "$base_abi" --apk "$apk"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nkos-sign-repository.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/repository/riscv64"

python3 - "$staging/staging.json" "$staging" "$repo" "$base_abi" "$repository_commit" "$tmp/records.txt" "$apk" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys

staging_manifest = pathlib.Path(sys.argv[1]).resolve()
staging = pathlib.Path(sys.argv[2]).resolve()
repo = pathlib.Path(sys.argv[3]).resolve()
base_abi = sys.argv[4]
commit = sys.argv[5]
records_out = pathlib.Path(sys.argv[6])
apk = pathlib.Path(sys.argv[7])

document = json.loads(staging_manifest.read_text(encoding="utf-8"))
if document.get("schema") != 1 or document.get("base_abi") != base_abi:
    raise SystemExit("sign-repository: staging contract mismatch")
if document.get("repository_commit") != commit:
    raise SystemExit("sign-repository: staging repository commit mismatch")
records = document.get("packages")
if not isinstance(records, list) or not records:
    raise SystemExit("sign-repository: staging package list is empty")

def under(root: pathlib.Path, relative: object, label: str) -> pathlib.Path:
    if not isinstance(relative, str) or not relative or pathlib.PurePosixPath(relative).is_absolute():
        raise SystemExit(f"sign-repository: unsafe {label}: {relative!r}")
    path = (root / relative).resolve()
    if root not in path.parents:
        raise SystemExit(f"sign-repository: {label} escaped staging: {relative!r}")
    return path

source_manifests = {}
for recipe in sorted((repo / "recipes").iterdir()):
    if not recipe.is_dir():
        continue
    manifest_path = recipe / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    source_manifests[manifest["package"]] = (manifest, manifest_path)

seen = set()
metadata_paths = []
for record in records:
    if not isinstance(record, dict):
        raise SystemExit("sign-repository: malformed staging record")
    name = record.get("name")
    version = record.get("version")
    if not isinstance(name, str) or not isinstance(version, str) or (name, version) in seen:
        raise SystemExit("sign-repository: duplicate or malformed staged identity")
    seen.add((name, version))
    if record.get("arch") != "riscv64":
        raise SystemExit(f"sign-repository: staged package has wrong arch: {name}")
    metadata_path = under(staging, record.get("metadata"), "metadata path")
    files_dir = under(staging, record.get("files"), "files path")
    if not metadata_path.is_file() or not files_dir.is_dir():
        raise SystemExit(f"sign-repository: staged files missing for {name}-{version}")
    if hashlib.sha256(metadata_path.read_bytes()).hexdigest() != record.get("metadata_sha256"):
        raise SystemExit(f"sign-repository: staged metadata hash mismatch: {name}-{version}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if metadata.get("schema") != 1 or metadata.get("name") != name or metadata.get("version") != version or metadata.get("arch") != "riscv64":
        raise SystemExit(f"sign-repository: staged metadata identity mismatch: {name}-{version}")
    source = source_manifests.get(name)
    if source is None:
        raise SystemExit(f"sign-repository: staged package is not in checked-out recipes: {name}")
    source_manifest, source_path = source
    if source_manifest.get("package") != name:
        raise SystemExit(f"sign-repository: source package mismatch: {name}")
    sys.path.insert(0, str(repo / "scripts"))
    from package_version import canonical_version
    expected_version = canonical_version(source_manifest, apk)
    if expected_version != version:
        raise SystemExit(f"sign-repository: staged version does not match source: {name}")
    expected_descriptor = {
        "id": source_manifest["id"],
        "package": name,
        "source_version": source_manifest["source_version"],
        "pkgver": source_manifest["pkgver"],
        "pkgrel": source_manifest["pkgrel"],
        "version": version,
        "base_abi": base_abi,
        "server_api": source_manifest["server_api"],
        "features": source_manifest["features"],
        "config": source_manifest["config"],
        "data": source_manifest["data"],
        "services": source_manifest["services"],
        "preserve": ["config", "data"],
    }
    expected_recipe_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
    if metadata.get("recipe_manifest_sha256") != expected_recipe_hash:
        raise SystemExit(f"sign-repository: staged recipe manifest hash mismatch: {name}")
    if metadata.get("descriptor") != expected_descriptor or record.get("descriptor") != expected_descriptor:
        raise SystemExit(f"sign-repository: staged descriptor does not match source: {name}-{version}")
    expected_depends = " ".join([base_abi, "nkos-server-api=1", *source_manifest["features"], *source_manifest.get("depends", [])])
    for key, expected in {
        "description": source_manifest["description"],
        "license": source_manifest["license"],
        "maintainer": source_manifest.get("maintainer", "NanoKVM OS maintainers"),
        "origin": name,
        "depends": expected_depends,
        "tags": "nkos-addon",
    }.items():
        if metadata.get(key) != expected:
            raise SystemExit(f"sign-repository: staged metadata field mismatch: {key}: {name}-{version}")
    files = metadata.get("files")
    if not isinstance(files, dict) or not files:
        raise SystemExit(f"sign-repository: staged file list is empty: {name}-{version}")
    package_id = source_manifest["id"]
    prefix = f"addons/{package_id}/"
    actual = {}
    for root, dirs, filenames in os.walk(files_dir, topdown=True, followlinks=False):
        for item in list(dirs) + list(filenames):
            path = pathlib.Path(root) / item
            if path.is_symlink():
                raise SystemExit(f"sign-repository: symlink in staged payload: {path}")
        dirs[:] = [item for item in dirs if not (pathlib.Path(root) / item).is_symlink()]
        for item in filenames:
            path = pathlib.Path(root) / item
            relative = path.relative_to(files_dir).as_posix()
            if not relative.startswith(prefix) or any(part in ("", ".", "..") for part in pathlib.PurePosixPath(relative).parts):
                raise SystemExit(f"sign-repository: payload escaped addon namespace: {relative}")
            if any(relative.endswith(suffix) for suffix in (".pre-install", ".post-install", ".pre-upgrade", ".post-upgrade", ".trigger")):
                raise SystemExit(f"sign-repository: package script path is forbidden: {relative}")
            actual[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != files:
        raise SystemExit(f"sign-repository: staged file hashes do not match metadata: {name}-{version}")
    metadata_paths.append(metadata_path.relative_to(staging).as_posix())

expected_metadata = {
    path.relative_to(staging).as_posix()
    for path in staging.glob("packages/*/metadata.json")
}
if set(metadata_paths) != expected_metadata:
    raise SystemExit("sign-repository: unlisted or missing staged package metadata")
records_out.write_text("\n".join(metadata_paths) + "\n", encoding="utf-8")
PY

if [ -n "$previous" ]; then
	[ -d "$previous" ] && [ -f "$previous/manifest.json" ] || {
		echo "sign-repository: previous repository is incomplete: $previous" >&2
		exit 2
	}
	python3 - "$previous" "$tmp/repository" <<'PY'
import hashlib
import json
import pathlib
import re
import shutil
import sys

previous = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
manifest = json.loads((previous / "manifest.json").read_text(encoding="utf-8"))
records = manifest.get("packages")
if not isinstance(records, list):
    raise SystemExit("sign-repository: previous manifest has no package list")
for record in records:
    if not isinstance(record, dict):
        raise SystemExit("sign-repository: previous package record is malformed")
    relative = record.get("path")
    expected = record.get("sha256")
    if not isinstance(relative, str) or not relative.startswith("riscv64/") or ".." in pathlib.PurePosixPath(relative).parts:
        raise SystemExit(f"sign-repository: previous package path is unsafe: {relative!r}")
    source = (previous / relative).resolve()
    if previous not in source.parents or not source.is_file():
        raise SystemExit(f"sign-repository: previous package is missing: {relative}")
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected) or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"sign-repository: previous package hash mismatch: {relative}")
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
PY
fi

while IFS= read -r metadata_rel; do
	[ "$metadata_rel" ] || continue
	metadata="$staging/$metadata_rel"
	files_dir="$(dirname "$metadata")/files"
	package=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$metadata")
	version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$metadata")
	arch=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["arch"])' "$metadata")
	description=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["description"])' "$metadata")
	license=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$metadata")
	maintainer=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("maintainer","NanoKVM OS maintainers"))' "$metadata")
	depends=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["depends"])' "$metadata")
	tags=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tags","nkos-addon"))' "$metadata")
	pkg="$tmp/repository/riscv64/$package-$version.apk"
	candidate="$tmp/$package-$version.apk"
	find "$files_dir" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
	"$apk" --sign-key "$sign_key" mkpkg --compat 3.0.8 --files "$files_dir" --output "$candidate" \
		--info "name:$package" --info "version:$version" --info "arch:$arch" \
		--info "description:$description" --info "license:$license" \
		--info "maintainer:$maintainer" --info "origin:$package" \
		--info "build-time:$SOURCE_DATE_EPOCH" --info "depends:$depends" --info "tags:$tags"
	"$apk" --keys-dir "$verify_keys_dir" verify "$candidate"
	if [ -e "$pkg" ]; then
		cmp -s "$candidate" "$pkg" || {
			echo "sign-repository: package bytes changed for published identity: $package-$version" >&2
			exit 1
		}
		rm -f "$candidate"
	else
		mv "$candidate" "$pkg"
	fi
done < "$tmp/records.txt"

set -- "$tmp/repository/riscv64/"*.apk
[ -f "$1" ] || {
	echo 'sign-repository: no packages were generated' >&2
	exit 1
}
index="$tmp/repository/riscv64/Packages.adb"
"$apk" --keys-dir "$verify_keys_dir" --sign-key "$sign_key" mkndx \
	--output "$index" --description "NanoKVM OS packages $repository_commit" \
	--pkgname-spec '${arch}/${name}-${version}.apk' "$@"
"$apk" --keys-dir "$verify_keys_dir" verify "$index"

python3 - "$tmp/repository" "$staging" "$tmp/records.txt" "$base_abi" "$repository_commit" "$previous" <<'PY'
import hashlib
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
staging = pathlib.Path(sys.argv[2])
records_path = pathlib.Path(sys.argv[3])
base_abi = sys.argv[4]
commit = sys.argv[5]
previous = pathlib.Path(sys.argv[6]) if sys.argv[6] else None
metadata_paths = [pathlib.Path(line.strip()) for line in records_path.read_text(encoding="utf-8").splitlines() if line.strip()]
packages = []
addons = []
features = set()
world = []
for relative in metadata_paths:
    metadata = json.loads((staging / relative).read_text(encoding="utf-8"))
    name = metadata["name"]
    version = metadata["version"]
    descriptor = metadata["descriptor"]
    addons.append(descriptor)
    features.update(descriptor["features"])
    world.append(f"{name}={version}")
    package_path = out / "riscv64" / f"{name}-{version}.apk"
    packages.append({
        "addon": descriptor["id"],
        "name": name,
        "version": version,
        "arch": "riscv64",
        "sha256": hashlib.sha256(package_path.read_bytes()).hexdigest(),
        "path": package_path.relative_to(out).as_posix(),
    })
if previous is not None:
    old = json.loads((previous / "manifest.json").read_text(encoding="utf-8"))
    current_package_keys = {(item["name"], item["version"], item["arch"]) for item in packages}
    for item in old.get("packages", []):
        key = (item.get("name"), item.get("version"), item.get("arch"))
        if key in current_package_keys:
            continue
        package_path = out / item["path"]
        if not package_path.is_file():
            raise SystemExit(f"sign-repository: retained package is missing: {item['path']}")
        packages.append(item)
index = out / "riscv64" / "Packages.adb"
manifest = {
    "schema": 1,
    "repository_commit": commit,
    "base_abi": base_abi,
    "server_api": "nkos-server-api=1",
    "features": sorted(features),
    "world": sorted(world),
    "addons": addons,
    "packages": packages,
    "repository": {
        "index": "riscv64/Packages.adb",
        "index_sha256": hashlib.sha256(index.read_bytes()).hexdigest(),
    },
}
(out / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

mkdir -p "$(dirname "$output")"
mv "$tmp/repository" "$output"
echo "signed NanoKVM addon repository written to $output"
