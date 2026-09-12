#!/bin/sh
set -eu

destination=${1:?package staging directory is required}
compiler=${NKOS_TARGET_CC:-${CC:-}}
[ -n "$compiler" ] || {
	echo 'nkos-addon-system-info: NKOS_TARGET_CC must name the Buildroot riscv64/musl compiler' >&2
	exit 2
}
mkdir -p "$destination/addons/system-info/bin"
"$compiler" ${NKOS_TARGET_CFLAGS:-} -Os -static -s \
	-o "$destination/addons/system-info/bin/system-info" \
	"$(dirname "$0")/src/system-info.c"
chmod 0755 "$destination/addons/system-info/bin/system-info"
