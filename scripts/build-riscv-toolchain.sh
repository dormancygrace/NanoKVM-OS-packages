#!/bin/sh
# Build the pinned Buildroot riscv64/musl compiler used by addon recipes.
# This downloads source archives only; no external binary toolchain is trusted.
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
source_tar=
output=
dl_dir=

usage() {
	echo "usage: $0 --source-tar BUILDROOT_TAR --out BUILDROOT_OUTPUT [--dl-dir DIR]" >&2
	exit 2
}
while [ "$#" -gt 0 ]; do
	case $1 in
		--source-tar) [ "$#" -ge 2 ] || usage; source_tar=$2; shift 2;;
		--out) [ "$#" -ge 2 ] || usage; output=$2; shift 2;;
		--dl-dir) [ "$#" -ge 2 ] || usage; dl_dir=$2; shift 2;;
		*) usage;;
	esac
done
[ -n "$source_tar" ] && [ -f "$source_tar" ] || usage
[ -n "$output" ] || usage
[ ! -e "$output" ] || {
	echo "build-riscv-toolchain: output already exists: $output" >&2
	exit 2
}
. "$repo/versions.env"
[ "${BUILDROOT_VERSION:-}" = 2026.08 ] || {
	echo 'build-riscv-toolchain: unexpected Buildroot version pin' >&2
	exit 1
}
got=$(sha256sum "$source_tar" | awk '{print $1}')
[ "$got" = "$BUILDROOT_SOURCE_SHA256" ] || {
	echo 'build-riscv-toolchain: Buildroot source digest mismatch' >&2
	exit 1
}
command -v make >/dev/null 2>&1 || { echo 'build-riscv-toolchain: make is required' >&2; exit 127; }
command -v tar >/dev/null 2>&1 || { echo 'build-riscv-toolchain: tar is required' >&2; exit 127; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nkos-buildroot-toolchain.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/source"
tar -xf "$source_tar" -C "$tmp/source" --strip-components=1
if [ -z "$dl_dir" ]; then
	dl_dir=$tmp/dl
fi
mkdir -p "$dl_dir"
mkdir -p "$(dirname "$output")"
cat > "$tmp/defconfig" <<EOF
BR2_riscv=y
BR2_RISCV_64=y
BR2_RISCV_ISA_RVC=y
BR2_TOOLCHAIN_BUILDROOT_MUSL=y
BR2_TARGET_OPTIMIZATION="-march=rv64gc -mabi=lp64d"
BR2_REPRODUCIBLE=y
BR2_DL_DIR="$dl_dir"
EOF
mkdir "$output"
PATH=/usr/bin:/bin make -C "$tmp/source" O="$output" \
	BR2_DEFCONFIG="$tmp/defconfig" defconfig
PATH=/usr/bin:/bin make -C "$tmp/source" O="$output" toolchain -j2
compiler="$output/host/bin/riscv64-buildroot-linux-musl-gcc"
[ -x "$compiler" ] || {
	echo 'build-riscv-toolchain: Buildroot did not produce the musl compiler' >&2
	exit 1
}
"$compiler" -dumpmachine | grep -Eq '^riscv64-buildroot-linux-musl$'
"$compiler" -print-file-name=libc.a | grep -Fq "$output/host/"
echo "Buildroot $BUILDROOT_VERSION riscv64/musl toolchain ready: $compiler"
