#!/bin/bash
# The Galaxy S9's (SM-G960F, starlte) TWRP installer for Scion: one zip that writes Scion's boot image to BOOT and the
# iOS system image to a partition of the flash (SYSTEM by default, which Android then loses), from which the kernel's
# init makes it the root (boot-arg system_apfs=ufs_PARTITION, the flash read through the loader: ufs=2).
#
#   starlte/mkinstaller.sh -s system.apfs [-K kernel-repo] [-k kernel] [-r root.apfs] [-p PARTITION] [-t SECS]
#                          [-o installer.zip] [extra boot-args...]
#
#   -s  the iOS system image (userland/system.apfs of the kernel repo, built from your own IPSW)
#   -K  the kernel repository (Scion-Project/hackios-xnu-kernel), for its devices/starlte/mkimage.sh and loader;
#       default $SCION_KERNEL, else ../hackios-xnu-kernel beside this repository
#   -k  the S9's kernel (make starlte_defconfig && make kernel there); default its hakios-kernel
#   -r  the small root, built for this: (cd userland && GL=1 NO_AIR=1 REST=1 ALONE=1 RC=rc.launchd bash build.sh);
#       default its userland/root.apfs
#   -p  the partition the system image goes to (SYSTEM)
#   -t  a test run: after SECS seconds the loader takes the phone back, keeps the log in pstore and restarts into TWRP
#       (0, the default: no time limit; five fingers on the screen or Vol Down + Power still end it)
#   -o  the zip (out/scion-starlte-installer.zip)
#
# The zip carries iOS's own files, from your IPSW, and the loader carries your iPhone's identity: it is yours to hand on
# privately, never to be published or committed (.gitignore keeps it out of this repository).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KREPO=${SCION_KERNEL:-$REPO/../hackios-xnu-kernel}
SYSTEM= KERNEL= ROOT= PART=SYSTEM SECS=0 OUT=$REPO/out/scion-starlte-installer.zip
while getopts s:K:k:r:p:t:o: opt; do
	case $opt in
	s) SYSTEM=$OPTARG ;; K) KREPO=$OPTARG ;; k) KERNEL=$OPTARG ;; r) ROOT=$OPTARG ;; p) PART=$OPTARG ;; t) SECS=$OPTARG ;; o) OUT=$OPTARG ;;
	*) sed -n 2,20p "$0"; exit 2 ;;
	esac
done
shift $((OPTIND - 1))
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
[ -n "$SYSTEM" ] || { echo "mkinstaller.sh: -s system.apfs is required" >&2; exit 2; }
KREPO=$(cd "$KREPO" && pwd)
SYSTEM=$(abs "$SYSTEM") OUT=$(abs "$OUT")
KERNEL=$(abs "${KERNEL:-$KREPO/hakios-kernel}") ROOT=$(abs "${ROOT:-$KREPO/userland/root.apfs}")
for f in "$SYSTEM" "$KERNEL" "$ROOT" "$KREPO/devices/starlte/mkimage.sh"; do
	[ -f "$f" ] || { echo "mkinstaller.sh: $f is missing" >&2; exit 1; }
done
# an APFS container ("NXSB" at 32), and a small root that can start the system image's boot (ALONE=1, RC=rc.launchd)
[ "$(dd if="$SYSTEM" bs=1 skip=32 count=4 2>/dev/null)" = NXSB ] || { echo "mkinstaller.sh: $SYSTEM is not an APFS container" >&2; exit 1; }
case "$SECS" in *[!0-9]*|'') echo "mkinstaller.sh: -t $SECS: seconds, a number" >&2; exit 2 ;; esac
case "$PART" in *[!A-Za-z0-9_]*|'') echo "mkinstaller.sh: -p $PART: a partition name, letters, digits and _" >&2; exit 2 ;; esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/scion-installer.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# The boot image: the time limit of -t, the kernel on cores 2-3 and the loader on core 0 serving the flash (ufs=2), the
# drivers that have a safe default, and the system image's partition. Core 1 is never the kernel's: S-Boot powers it up
# and parks it before the hand-over (seen on the phone, 29 October 2026), so a kernel started there never runs.
ARGS="cpus=4 bootcpu=2 exynos_keys=1 max77705=1 panel=1 s6sy761=1 ufs=2 system_apfs=ufs_$PART $*"
"$KREPO/devices/starlte/mkimage.sh" -o "$WORK/boot.img" -k "$KERNEL" -r "$ROOT" -s "$SECS" $ARGS | sed 's/^/  /'
BUILD="Scion $(git -C "$KREPO" describe --always --dirty 2>/dev/null || echo '?'), $(date -u +%Y-%m-%d), system on $PART$([ "$SECS" = 0 ] || echo ", back to TWRP after $SECS s")"
sed -e "s|@BUILD@|$BUILD|" -e "s|@PART@|$PART|" "$HERE/installer.prop.in" > "$WORK/installer.prop.in"
mkdir -p "$(dirname "$OUT")"
python3 "$REPO/tools/storedzip.py" "$OUT" "$WORK/installer.prop.in" \
	META-INF/com/google/android/update-binary="$HERE/update-binary" \
	META-INF/com/google/android/updater-script="$HERE/updater-script" \
	boot.img="$WORK/boot.img" system.apfs="$SYSTEM"
echo "mkinstaller.sh: $OUT: $(( $(wc -c < "$OUT") / 1048576 )) MB, the system image to $PART; boot-args: $ARGS"
echo "mkinstaller.sh: yours only (iOS's files and your iPhone's identity are in it): hand it on privately"
