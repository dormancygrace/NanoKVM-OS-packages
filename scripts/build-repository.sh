#!/bin/sh
# Build and sign a complete NanoKVM addon repository snapshot.
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
apk=
base_abi=
sign_key=
verify_keys_dir=$repo/keys
output=
previous=
repository_commit=${REPOSITORY_COMMIT:-}

usage() {
	echo "usage: $0 --apk APK --base-abi nkos-base-abi=X.Y.Z --sign-key PRIVATE_KEY [--verify-keys-dir DIR] [--previous DIR] --out DIR" >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case $1 in
		--apk) [ "$#" -ge 2 ] || usage; apk=$2; shift 2;;
		--base-abi) [ "$#" -ge 2 ] || usage; base_abi=$2; shift 2;;
		--sign-key) [ "$#" -ge 2 ] || usage; sign_key=$2; shift 2;;
		--verify-keys-dir) [ "$#" -ge 2 ] || usage; verify_keys_dir=$2; shift 2;;
		--previous) [ "$#" -ge 2 ] || usage; previous=$2; shift 2;;
		--out) [ "$#" -ge 2 ] || usage; output=$2; shift 2;;
		*) usage;;
	esac
done

[ -n "$apk" ] && [ -x "$apk" ] || {
	echo 'build-repository: executable --apk is required' >&2
	exit 2
}
[ -n "$base_abi" ] || usage
printf '%s\n' "$base_abi" | grep -Eq '^nkos-base-abi=[0-9]+\.[0-9]+\.[0-9]+$' || {
	echo "build-repository: invalid exact base ABI: $base_abi" >&2
	exit 2
}
[ -f "$sign_key" ] || {
	echo 'build-repository: signing key is required' >&2
	exit 2
}
[ -d "$verify_keys_dir" ] || {
	echo "build-repository: public trust key directory is missing: $verify_keys_dir" >&2
	exit 2
}
[ -n "$output" ] || usage
case $output in /|.|..|'') echo 'build-repository: unsafe output path' >&2; exit 2;; esac
[ ! -e "$output" ] || {
	echo "build-repository: output already exists: $output" >&2
	exit 2
}

if [ -z "$repository_commit" ] && git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
	repository_commit=$(git -C "$repo" rev-parse HEAD)
fi
printf '%s\n' "$repository_commit" | grep -Eq '^[0-9a-fA-F]{40}$' || {
	echo 'build-repository: a pinned 40-character REPOSITORY_COMMIT is required' >&2
	exit 2
}

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
case $SOURCE_DATE_EPOCH in ''|*[!0-9]*)
	echo 'build-repository: SOURCE_DATE_EPOCH must be an unsigned integer' >&2
	exit 2;;
esac
export SOURCE_DATE_EPOCH

# Recipe builds run without any ambient signing-key variables.
unset APK_SIGNING_KEY NKOS_SIGNING_KEY SIGNING_KEY

python3 "$here/validate-repository.py" --root "$repo" --base-abi "$base_abi" --apk "$apk"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nkos-repository.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/repository/riscv64"
if [ -n "$previous" ]; then
	[ -d "$previous" ] && [ -f "$previous/manifest.json" ] || {
		echo "build-repository: previous repository is incomplete: $previous" >&2
		exit 2
	}
	# Carry every previously published package into the new snapshot.  The
	# manifest hashes are checked before use, so a stale or tampered Pages
	# snapshot cannot become trusted input.
	python3 - "$previous" "$tmp/repository" <<'PY'
import hashlib
import json
import pathlib
import shutil
import sys

previous = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
manifest = json.loads((previous / "manifest.json").read_text(encoding="utf-8"))
records = manifest.get("packages")
if not isinstance(records, list):
    raise SystemExit("build-repository: previous manifest has no package list")
for record in records:
    if not isinstance(record, dict):
        raise SystemExit("build-repository: previous package record is malformed")
    relative = record.get("path")
    expected = record.get("sha256")
    if not isinstance(relative, str) or not relative.startswith("riscv64/"):
        raise SystemExit(f"build-repository: previous package path is unsafe: {relative!r}")
    source = (previous / relative).resolve()
    if previous not in source.parents or not source.is_file():
        raise SystemExit(f"build-repository: previous package is missing: {relative}")
    if not isinstance(expected, str) or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"build-repository: previous package hash mismatch: {relative}")
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
PY
fi

for recipe in "$repo"/recipes/*; do
	[ -d "$recipe" ] || continue
	manifest=$recipe/manifest.json
	id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$manifest")
	package=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package"])' "$manifest")
	version=$(python3 "$here/package_version.py" "$manifest" --apk "$apk")
	stage=$tmp/stage-$id
	mkdir -p "$stage"
	cp -a "$recipe/files/." "$stage/"
	sh "$recipe/build.sh" "$stage"
	python3 "$here/render-addon.py" "$manifest" "$base_abi" "$stage/addons/$id/addon.json" --apk "$apk"
	python3 - "$stage" "$id" "$manifest" <<'PY'
import json
import os
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
addon_id = sys.argv[2]
manifest = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
prefix = pathlib.PurePosixPath("addons") / addon_id
addons_root = pathlib.PurePosixPath("addons")
errors = []
for root, dirs, files in os.walk(stage, topdown=True, followlinks=False):
    for name in list(dirs) + list(files):
        path = pathlib.Path(root) / name
        rel = pathlib.PurePosixPath(path.relative_to(stage).as_posix())
        if path.is_symlink():
            errors.append(f"symlink: {rel}")
        if rel not in (addons_root, prefix) and prefix not in rel.parents:
            errors.append(f"outside addon namespace: {rel}")
        if not path.is_dir() and not path.is_file():
            errors.append(f"unsupported payload object: {rel}")
    dirs[:] = [name for name in dirs if not (pathlib.Path(root) / name).is_symlink()]
for relative in manifest.get("generated_files", []):
    path = stage / relative
    if not path.is_file() or path.is_symlink():
        errors.append(f"missing generated payload: {relative}")
if errors:
    print("build-repository: unsafe recipe output", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)
PY
	features=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["features"]))' "$manifest")
	deps="$base_abi nkos-server-api=1 $features"
	pkg="$tmp/repository/riscv64/$package-$version.apk"
	candidate="$tmp/$package-$version.apk"
	find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
	name_description=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["description"])' "$manifest")
	name_license=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$manifest")
	name_maintainer=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("maintainer","NanoKVM OS maintainers"))' "$manifest")
	"$apk" --sign-key "$sign_key" mkpkg --compat 3.0.8 --files "$stage" --output "$candidate" \
		--info "name:$package" --info "version:$version" --info 'arch:riscv64' \
		--info "description:$name_description" --info "license:$name_license" \
		--info "maintainer:$name_maintainer" --info "origin:$package" \
		--info "build-time:$SOURCE_DATE_EPOCH" \
		--info "depends:$deps" --info 'tags:nkos-addon'
	# Check every package with the same isolated trust store used for the index.
	"$apk" --keys-dir "$verify_keys_dir" verify "$candidate"
	if [ -e "$pkg" ]; then
		# A published identity is immutable.  A packaging fix must increment
		# pkgrel, producing a distinct filename, rather than replacing bytes.
		cmp -s "$candidate" "$pkg" || {
			echo "build-repository: package bytes changed for published identity: $package-$version" >&2
			exit 1
		}
		rm -f "$candidate"
	else
		mv "$candidate" "$pkg"
	fi
done

set -- "$tmp/repository/riscv64/"*.apk
[ -f "$1" ] || {
	echo 'build-repository: no packages were generated' >&2
	exit 1
}
index=$tmp/repository/riscv64/Packages.adb
"$apk" --keys-dir "$verify_keys_dir" --sign-key "$sign_key" mkndx \
	--output "$index" --description "NanoKVM OS packages $repository_commit" \
	--pkgname-spec '${name}-${version}.apk' "$@"
"$apk" --keys-dir "$verify_keys_dir" verify "$index"

python3 - "$tmp/repository" "$repo" "$base_abi" "$repository_commit" "$previous" <<'PY'
import hashlib
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
base_abi = sys.argv[3]
commit = sys.argv[4]
previous = pathlib.Path(sys.argv[5]) if sys.argv[5] else None
packages = []
addons = []
features = set()
world = []
for recipe in sorted((source / "recipes").iterdir()):
    if not recipe.is_dir():
        continue
    m = json.loads((recipe / "manifest.json").read_text(encoding="utf-8"))
    version = f'{m["pkgver"]}-r{m["pkgrel"]}'
    descriptor = {
        "id": m["id"],
        "package": m["package"],
        "source_version": m["source_version"],
        "pkgver": m["pkgver"],
        "pkgrel": m["pkgrel"],
        "version": version,
        "base_abi": base_abi,
        "server_api": m["server_api"],
        "features": m["features"],
        "config": m["config"],
        "data": m["data"],
        "services": m["services"],
        "preserve": ["config", "data"],
    }
    addons.append(descriptor)
    features.update(m["features"])
    world.append(f'{m["package"]}={version}')
    package_path = out / "riscv64" / f'{m["package"]}-{version}.apk'
    packages.append({
        "addon": m["id"],
        "name": m["package"],
        "version": version,
        "arch": "riscv64",
        "sha256": hashlib.sha256(package_path.read_bytes()).hexdigest(),
        "path": package_path.relative_to(out).as_posix(),
    })

# Keep hashes and package records for retained revisions copied from the
# previous snapshot.  The active addon descriptors/world below name current
# revisions while old APKs remain addressable for rollback and audit.
if previous is not None:
    old = json.loads((previous / "manifest.json").read_text(encoding="utf-8"))
    current_package_keys = {(item["name"], item["version"], item["arch"]) for item in packages}
    for item in old.get("packages", []):
        key = (item.get("name"), item.get("version"), item.get("arch"))
        if key in current_package_keys:
            continue
        package_path = out / item["path"]
        if not package_path.is_file():
            raise SystemExit(f"retained package is missing: {item['path']}")
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
