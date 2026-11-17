#!/bin/bash
# SPDX-License-Identifier: MIT-0
# Build the Scion repository into a directory you can serve as it is (any static web server, or GitHub Pages):
#   repo/build.sh KERNEL_CHECKOUT OUT_DIR [mkrepo.py options, e.g. --sign KEYID]
# With APPS_WORK=DIR (and THEOS) it also builds the open-source apps of repo/apps/ from source (repo/mkapps.py):
# their checkouts and builds go in DIR, which is to be outside any of Scion's git repositories.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=${1:?usage: repo/build.sh KERNEL_CHECKOUT OUT_DIR}
OUT=${2:?usage: repo/build.sh KERNEL_CHECKOUT OUT_DIR}
shift 2
rm -rf "$OUT"
python3 "$HERE/mkdebs.py" --kernel "$KERNEL" --out "$OUT"
if [ -n "${APPS_WORK:-}" ]; then
	python3 "$HERE/mkapps.py" --work "$APPS_WORK" --out "$OUT" ${APPS_NO_BUILD:+--no-build}
fi
python3 "$HERE/mkrepo.py" "$OUT" "$@"
