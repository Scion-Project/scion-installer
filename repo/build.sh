#!/bin/bash
# SPDX-License-Identifier: MIT-0
# Build the Scion repository into a directory you can serve as it is (any static web server, or GitHub Pages):
#   repo/build.sh KERNEL_CHECKOUT OUT_DIR [mkrepo.py options, e.g. --sign KEYID]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=${1:?usage: repo/build.sh KERNEL_CHECKOUT OUT_DIR}
OUT=${2:?usage: repo/build.sh KERNEL_CHECKOUT OUT_DIR}
shift 2
rm -rf "$OUT"
python3 "$HERE/mkdebs.py" --kernel "$KERNEL" --out "$OUT"
python3 "$HERE/mkrepo.py" "$OUT" "$@"
