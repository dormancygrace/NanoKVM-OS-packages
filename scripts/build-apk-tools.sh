#!/bin/sh
# Build the exact apk-tools source pin used by NanoKVM OS package CI.
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
source_dir=
source_tar=
output=

usage() {
	echo "usage: $0 --source-dir APK_TOOLS_CHECKOUT --out APK_PATH [--source-tar FILE]" >&2
	exit 2
}
while [ "$#" -gt 0 ]; do
	case $1 in
		--source-dir) [ "$#" -ge 2 ] || usage; source_dir=$2; shift 2;;
		--source-tar) [ "$#" -ge 2 ] || usage; source_tar=$2; shift 2;;
		--out) [ "$#" -ge 2 ] || usage; output=$2; shift 2;;
		*) usage;;
	esac
done
[ -n "$output" ] || usage
test -f "$repo/versions.env"
# versions.env is reviewed repository metadata, not user-controlled shell.
. "$repo/versions.env"
[ "${APK_TOOLS_VERSION:-}" = 3.0.8 ] || {
	echo 'build-apk-tools: versions.env has an unexpected apk-tools version' >&2
	exit 1
}
[ "${APK_TOOLS_SOURCE_SHA256:-}" ] || {
	echo 'build-apk-tools: source digest is missing' >&2
	exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nkos-apk-tools.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if [ -n "$source_tar" ]; then
	[ -f "$source_tar" ] || { echo "build-apk-tools: source tar not found: $source_tar" >&2; exit 1; }
	got=$(sha256sum "$source_tar" | awk '{print $1}')
	[ "$got" = "$APK_TOOLS_SOURCE_SHA256" ] || {
		echo 'build-apk-tools: source tar digest mismatch' >&2
		exit 1
	}
	mkdir "$tmp/source"
	tar -xf "$source_tar" -C "$tmp/source" --strip-components=1
	source_dir=$tmp/source
fi
[ -n "$source_dir" ] && [ -d "$source_dir" ] || {
	echo 'build-apk-tools: provide a checked-out or hash-verified source tree' >&2
	exit 2
}
if [ -d "$source_dir/.git" ]; then
	tag=$(git -C "$source_dir" describe --tags --exact-match 2>/dev/null || true)
	[ "$tag" = "$APK_TOOLS_TAG" ] || {
		echo "build-apk-tools: source is not exactly tag $APK_TOOLS_TAG" >&2
		exit 1
	}
fi
command -v meson >/dev/null 2>&1 || { echo 'build-apk-tools: meson is required' >&2; exit 127; }
command -v ninja >/dev/null 2>&1 || { echo 'build-apk-tools: ninja is required' >&2; exit 127; }

build="$tmp/build"
meson setup "$build" "$source_dir" \
	-Darch=riscv64 \
	-Ddefault_library=static \
	-Dcrypto_backend=openssl \
	-Ddocs=disabled \
	-Dhelp=disabled \
	-Dlua=disabled \
	-Dminimal=false \
	-Dpython=disabled \
	-Dtests=disabled \
	-Durl_backend=libfetch \
	-Dzstd=enabled \
	-Dbuildtype=release
ninja -C "$build"
apk_path=$(find "$build" -type f -name apk -perm -u+x -print -quit)
[ -n "$apk_path" ] || { echo 'build-apk-tools: apk executable was not produced' >&2; exit 1; }
install -D -m755 "$apk_path" "$output"
"$output" --version
