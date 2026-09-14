#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
NKOS_OPTIONAL_INPUT=${NKOS_PYTHON_INPUT:?NKOS_PYTHON_INPUT is required}
export NKOS_OPTIONAL_INPUT
exec python3 "$here/../../scripts/import-optional-package.py" python "$1"
