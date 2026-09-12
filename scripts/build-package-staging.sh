#!/bin/sh
# Build unsigned addon payload staging.  Recipe compilation runs in a job that
# has no signing-key environment or file.  A separate signer consumes this
# staging tree and never executes a recipe.
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
apk=
base_abi=
output=
repository_commit=${REPOSITORY_COMMIT:-}

usage() {
	echo "usage: $0 --apk APK --base-abi nkos-base-abi=X.Y.Z --out STAGING" >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case $1 in
		--apk) [ "$#" -ge 2 ] || usage; apk=$2; shift 2;;
		--base-abi) [ "$#" -ge 2 ] || usage; base_abi=$2; shift 2;;
		--out) [ "$#" -ge 2 ] || usage; output=$2; shift 2;;
		*) usage;;
	esac
done

[ -n "$apk" ] && [ -x "$apk" ] || {
	echo 'build-package-staging: executable --apk is required' >&2
	exit 2
}
[ "$base_abi" ] || usage
printf '%s\n' "$base_abi" | grep -Eq '^nkos-base-abi=[0-9]+\.[0-9]+\.[0-9]+$' || {
	echo "build-package-staging: invalid exact base ABI: $base_abi" >&2
	exit 2
}
[ -n "$output" ] || usage
case "$output" in /|.|..|'') echo 'build-package-staging: unsafe output path' >&2; exit 2;; esac
[ ! -e "$output" ] || {
	echo "build-package-staging: output already exists: $output" >&2
	exit 2
}
if [ -z "$repository_commit" ] && git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
	repository_commit=$(git -C "$repo" rev-parse HEAD)
fi
printf '%s\n' "$repository_commit" | grep -Eq '^[0-9a-fA-F]{40}$' || {
	echo 'build-package-staging: a pinned 40-character REPOSITORY_COMMIT is required' >&2
	exit 2
}

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
case "$SOURCE_DATE_EPOCH" in ''|*[!0-9]*) echo 'build-package-staging: SOURCE_DATE_EPOCH must be an unsigned integer' >&2; exit 2;; esac
export SOURCE_DATE_EPOCH
python3 "$here/validate-repository.py" --root "$repo" --base-abi "$base_abi" --apk "$apk"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nkos-package-staging.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
staging="$tmp/staging"
mkdir -p "$staging/packages"

# Do not allow an ambient secret to reach a recipe process.  CI also keeps the
# secret-backed signing job separate from this job entirely.
unset APK_SIGNING_KEY NKOS_SIGNING_KEY SIGNING_KEY

for recipe in "$repo"/recipes/*; do
	[ -d "$recipe" ] || continue
	manifest="$recipe/manifest.json"
	id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$manifest")
	package=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package"])' "$manifest")
	version=$(python3 "$here/package_version.py" "$manifest" --apk "$apk")
	stage="$tmp/stage-$id"
	mkdir -p "$stage"
	cp -a "$recipe/files/." "$stage/"
	env -u APK_SIGNING_KEY -u NKOS_SIGNING_KEY -u SIGNING_KEY \
		NKOS_TARGET_CC="${NKOS_TARGET_CC:-}" \
		NKOS_TARGET_CFLAGS="${NKOS_TARGET_CFLAGS:-}" \
		SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
		sh "$recipe/build.sh" "$stage"
	python3 "$here/render-addon.py" "$manifest" "$base_abi" "$stage/addons/$id/addon.json" --apk "$apk"
	find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
	python3 - "$stage" "$recipe" "$base_abi" "$package" "$version" "$staging" "$apk" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import sys

stage = pathlib.Path(sys.argv[1]).resolve()
recipe = pathlib.Path(sys.argv[2]).resolve()
base_abi = sys.argv[3]
package = sys.argv[4]
version = sys.argv[5]
staging = pathlib.Path(sys.argv[6]).resolve()
apk = pathlib.Path(sys.argv[7])
manifest = json.loads((recipe / "manifest.json").read_text(encoding="utf-8"))
addon_id = manifest["id"]
prefix = pathlib.PurePosixPath("addons") / addon_id
errors = []
for root, dirs, files in os.walk(stage, topdown=True, followlinks=False):
    for name in list(dirs) + list(files):
        path = pathlib.Path(root) / name
        rel = pathlib.PurePosixPath(path.relative_to(stage).as_posix())
        if path.is_symlink():
            errors.append(f"symlink: {rel}")
        if rel not in (pathlib.PurePosixPath("addons"), prefix) and prefix not in rel.parents:
            errors.append(f"outside addon namespace: {rel}")
        if not path.is_dir() and not path.is_file():
            errors.append(f"unsupported payload object: {rel}")
    dirs[:] = [name for name in dirs if not (pathlib.Path(root) / name).is_symlink()]
for relative in manifest.get("generated_files", []):
    path = stage / relative
    if not path.is_file() or path.is_symlink():
        errors.append(f"missing generated payload: {relative}")
if errors:
    print("build-package-staging: unsafe recipe output", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)

record_dir = staging / "packages" / f"{package}-{version}"
files_dir = record_dir / "files"
record_dir.mkdir(parents=True, exist_ok=False)
shutil.copytree(stage, files_dir, symlinks=False)
files = {}
for path in sorted(files_dir.rglob("*")):
    if path.is_symlink():
        raise SystemExit(f"build-package-staging: staged symlink: {path}")
    if path.is_file():
        relative = path.relative_to(files_dir).as_posix()
        files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()

descriptor = {
    "id": addon_id,
    "package": package,
    "source_version": manifest["source_version"],
    "pkgver": manifest["pkgver"],
    "pkgrel": manifest["pkgrel"],
    "version": version,
    "base_abi": base_abi,
    "server_api": manifest["server_api"],
    "features": manifest["features"],
    "config": manifest["config"],
    "data": manifest["data"],
    "services": manifest["services"],
    "preserve": ["config", "data"],
}
metadata = {
    "schema": 1,
    "name": package,
    "version": version,
    "arch": "riscv64",
    "description": manifest["description"],
    "license": manifest["license"],
    "maintainer": manifest.get("maintainer", "NanoKVM OS maintainers"),
    "origin": package,
    "build_time": int(os.environ["SOURCE_DATE_EPOCH"]),
    "depends": " ".join([base_abi, "nkos-server-api=1", *manifest["features"]]),
    "tags": "nkos-addon",
    "descriptor": descriptor,
    "recipe_manifest_sha256": hashlib.sha256((recipe / "manifest.json").read_bytes()).hexdigest(),
    "files": files,
}
(record_dir / "metadata.json").write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
done

python3 - "$staging" "$base_abi" "$repository_commit" <<'PY'
import hashlib
import json
import pathlib
import sys

staging = pathlib.Path(sys.argv[1]).resolve()
base_abi = sys.argv[2]
commit = sys.argv[3]
records = []
for metadata_path in sorted((staging / "packages").glob("*/metadata.json")):
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    files_dir = metadata_path.parent / "files"
    records.append({
        "name": metadata["name"],
        "version": metadata["version"],
        "arch": metadata["arch"],
        "metadata": metadata_path.relative_to(staging).as_posix(),
        "files": files_dir.relative_to(staging).as_posix(),
        "metadata_sha256": hashlib.sha256(metadata_path.read_bytes()).hexdigest(),
        "descriptor": metadata["descriptor"],
    })
if not records:
    raise SystemExit("build-package-staging: no recipes were staged")
(staging / "staging.json").write_text(
    json.dumps({
        "schema": 1,
        "base_abi": base_abi,
        "repository_commit": commit,
        "packages": records,
    }, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

mkdir -p "$(dirname "$output")"
mv "$staging" "$output"
echo "unsigned addon payload staging written to $output"
