#!/bin/bash
# The Galaxy S9's (SM-G960F, starlte) TWRP installer for Scion: one zip that writes Scion's boot image to BOOT and the
# iOS system image to a partition of the flash (SYSTEM by default, which Android then loses), from which the kernel's
# init makes it the root (boot-arg system_apfs=ufs_PARTITION, the flash read by the kernel's own UFS driver: ufs=3).
#
#   starlte/mkinstaller.sh -s system.apfs [-K kernel-repo] [-k kernel] [-r root.apfs] [-p PARTITION] [-t SECS]
#                          [-V] [-o installer.zip] [extra boot-args...]
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
#   -V  verbose: the kernel's log on the screen while it starts (mkimage.sh without -q). Off by default: on the phone
#       it covers the screen and makes iOS hard to use; the log is in pstore, and live over USB with usb_gadget=5.
#
# The zip carries iOS's own files, from your IPSW, and the loader carries your iPhone's identity: it is yours to hand on
# privately, never to be published or committed (.gitignore keeps it out of this repository).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KREPO=${SCION_KERNEL:-$REPO/../hackios-xnu-kernel}
SYSTEM= KERNEL= ROOT= PART=SYSTEM SECS=0 OUT=$REPO/out/scion-starlte-installer.zip QUIET=-q
while getopts s:K:k:r:p:t:o:V opt; do
	case $opt in
	s) SYSTEM=$OPTARG ;; K) KREPO=$OPTARG ;; k) KERNEL=$OPTARG ;; r) ROOT=$OPTARG ;; p) PART=$OPTARG ;; t) SECS=$OPTARG ;; o) OUT=$OPTARG ;; V) QUIET= ;;
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
# The boot image: the time limit of -t and the system image's partition, over the S9's defaults. Those are the kernel
# repository's (devices/starlte/configs/starlte.config, put on every image by devices/starlte/mkimage.sh; its README.md,
# "Defaults"): everything seen working on the phone -- six cores, the kernel's own UFS driver with /private/var kept in
# USERDATA, touch, keys, battery, USB console, GPU and governors, brightness, zero-copy display, the RTC, the front
# camera, the speakers and Wi-Fi. Extra boot-args given here go over them (name=value replaces a default, name= drops it).
grep -q -- '--with' "$KREPO/devices/starlte/mkimage.sh" || {
	echo "mkinstaller.sh: $KREPO/devices/starlte is older than the S9's defaults: tools/hakios-device.py sync starlte" >&2; exit 1; }
ARGS="system_apfs=ufs_$PART $*"
MADE=$("$KREPO/devices/starlte/mkimage.sh" $QUIET -o "$WORK/boot.img" -k "$KERNEL" -r "$ROOT" -s "$SECS" $ARGS)
echo "$MADE" | sed 's/^/  /'
# the line the image carries: the defaults with ARGS over them, as mkimage.sh said it
EFFECTIVE=$(echo "$MADE" | sed -n 's/^mkimage.sh: boot-args: \(.*\); [^;]*$/\1/p')
ARGS=${EFFECTIVE:-$ARGS}
BUILD="Scion $(git -C "$KREPO" describe --always --dirty 2>/dev/null || echo '?'), $(date -u +%Y-%m-%d), system on $PART$([ "$SECS" = 0 ] || echo ", back to TWRP after $SECS s")"
sed -e "s|@BUILD@|$BUILD|" -e "s|@PART@|$PART|" "$HERE/installer.prop.in" > "$WORK/installer.prop.in"
mkdir -p "$(dirname "$OUT")"
python3 "$REPO/tools/storedzip.py" "$OUT" "$WORK/installer.prop.in" \
	META-INF/com/google/android/update-binary="$HERE/update-binary" \
	META-INF/com/google/android/updater-script="$HERE/updater-script" \
	boot.img="$WORK/boot.img" system.apfs="$SYSTEM"
echo "mkinstaller.sh: $OUT: $(( $(wc -c < "$OUT") / 1048576 )) MB, the system image to $PART; boot-args: $ARGS"
echo "mkinstaller.sh: yours only (iOS's files and your iPhone's identity are in it): hand it on privately"
