#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
exec python3 "$here/../../scripts/import-optional-package.py" mc "$1"
