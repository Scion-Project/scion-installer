#!/bin/bash
# SPDX-License-Identifier: MIT-0
# ios27/build-ios27.sh: iOS 27 for the Galaxy S9 (SM-G960F, "starlte"), made on your own Mac from your own IPSW.
#
#   ./build-installer.sh --ios27 --ipsw ~/Downloads/iPhone12,1_27.2.1_24B156_Restore.ipsw --serial SERIAL
#   ios27/build-ios27.sh --ipsw IPSW --template recovery.img [--overlay DIR] [--flash SERIAL]
#
# It runs, in order, the steps of the kernel repository's docs/ios27/INSTALL-S9.md, at the commit pinned below, and stops at
# the first that fails:
#   1. the IPSW checked: its name, size and BuildManifest (version, build, iPhone12,1) against the kernel repository's
#      tools/ios27/builds/<BUILD>.conf, then its SHA-256 (--skip-hash skips only that)
#   2. the kernel (OS_PROFILE=ios-27 make kernel; the S9's Wi-Fi driver is built and linked by it)
#   3. your inputs from the IPSW (tools/ios27/s9/fetch-apple-inputs.sh: the three disk images and the iPhone 11's device tree)
#   4. the loader and the boot image (tools/ios27/s9/build-loader.sh, make-boot-image.sh: the phones' canvas and line)
#   5. the root image, only with --overlay DIR (the userland of INSTALL-S9.md section 4) and with sudo
#      (tools/ios27/s9/build-root.sh; about 62 GB free when it starts)
#   6. nothing is written to a phone unless --flash SERIAL is given; then the kernel repository's tools/ios27/s9/flash.sh
#      writes USERDATA (the root; it asks for the word ERASE) and BOOT, each read back and compared. Only those two.
#
#   --ipsw PATH        your own iPhone 11 restore image (iPhone12,1), of the build the kernel revision supports (24B156 by
#                      default: tools/ios27/builds/DEFAULT there; IOS27_BUILD=24A446 for 27.0.1). Never downloaded here.
#   --work DIR         where the kernel repository and the build go (./scion-build-ios27)
#   --out DIR          where the images and their SHA-256 go (./out/ios27)
#   --kernel-ref REF   the kernel repository's commit (default: KERNEL27_REV below)
#   --kernel FILE      a kernel already built (hakios-kernel of OS_PROFILE=ios-27 make kernel at the same revision): step 2 skipped
#   --inputs DIR       inputs fetch-apple-inputs.sh already made from this IPSW: step 3 checks them (SOURCE.txt's build and
#                      SHA-256s) instead of unpacking again; a copy (APFS clone) goes into the work directory
#   --template FILE    a copy of YOUR phone's RECOVERY partition (TWRP), the boot image's template; or
#   --serial SERIAL    read it from the phone in TWRP (flash.sh pull-template: read only)
#   --overlay DIR      the root's userland (INSTALL-S9.md section 4); without it the build stops after the boot image
#   --flash SERIAL     write the root and the boot image to that phone (in TWRP) at the end
#   --skip-hash        skip the IPSW's SHA-256
#   --dry-run          everything up to the boot image, then stop: no root, no phone written (what the project's
#                      gold-master check runs)
#
# Needs: a Mac with Apple silicon; Xcode 16.4 (DEVELOPER_DIR) and the Kernel Debug Kit 26.5 25F71 (KDKROOT), both Apple's and
# yours; jq, git, Android's adb; blacktop's ipsw; a Python 3 with numpy and ziglang (PY=, else ./venv made here).
# The images carry iOS's files and your IPSW's identity: they are yours, never to be published or shared.
set -euo pipefail

# The kernel repository's revision this builds: scion-kernel main with the first gold master's changes (moved with each tag).
KERNEL27_REPO=https://github.com/Scion-Project/scion-kernel.git
KERNEL27_REV=${KERNEL27_REV:-main}

HERE=$(cd "$(dirname "$0")" && pwd)
IPSW= WORK=$PWD/scion-build-ios27 OUT=$PWD/out/ios27 REF=$KERNEL27_REV KERNEL= INPUTS= TEMPLATE= SERIAL= OVERLAY= FLASH=
SKIP_HASH=0 DRY=0
die() { echo "build-ios27: $*" >&2; exit 1; }
step() { echo; echo "== build-ios27: $*"; }
while [ $# -gt 0 ]; do
	case "$1" in
	--ipsw) IPSW=$2; shift ;; --work) WORK=$2; shift ;; --out) OUT=$2; shift ;; --kernel-ref) REF=$2; shift ;;
	--kernel) KERNEL=$2; shift ;; --inputs) INPUTS=$2; shift ;; --template) TEMPLATE=$2; shift ;;
	--serial) SERIAL=$2; shift ;; --overlay) OVERLAY=$2; shift ;; --flash) FLASH=$2; shift ;;
	--skip-hash) SKIP_HASH=1 ;; --dry-run) DRY=1 ;;
	-h | --help) sed -n '3,40p' "$0"; exit 0 ;;
	*) die "unknown argument $1 (--help)" ;;
	esac
	shift
done
[ "$(uname -s)" = Darwin ] || die "iOS 27 is built on a Mac (Xcode, the Kernel Debug Kit, macOS's aea): this is $(uname -s)"
[ "$(uname -m)" = arm64 ] || die "a Mac with Apple silicon is needed (this is $(uname -m))"
[ -n "$IPSW" ] && [ -f "$IPSW" ] || die "--ipsw: your iPhone 11 restore image (iPhone12,1_27.2.1_24B156_Restore.ipsw)"
IPSW=$(cd "$(dirname "$IPSW")" && pwd)/$(basename "$IPSW")
[ "$DRY" = 0 ] || { OVERLAY=; FLASH=; }
[ -n "$TEMPLATE" ] || [ -n "$SERIAL" ] || die "the boot image needs your phone's TWRP as a template: --template FILE or --serial SERIAL"
[ -z "$TEMPLATE" ] || [ -f "$TEMPLATE" ] || die "--template: no file $TEMPLATE"
[ -z "$KERNEL" ] || [ -f "$KERNEL" ] || die "--kernel: no file $KERNEL"
[ -z "$INPUTS" ] || [ -f "$INPUTS/SOURCE.txt" ] || die "--inputs: $INPUTS has no SOURCE.txt (fetch-apple-inputs.sh writes one)"
[ -z "$OVERLAY" ] || [ -d "$OVERLAY" ] || die "--overlay: no directory $OVERLAY"
: "${DEVELOPER_DIR:?DEVELOPER_DIR: Xcode 16.4 (export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer)}"
[ -n "$KERNEL" ] || [ -d "${KDKROOT:-/nonexistent}" ] || die "KDKROOT: the Kernel Debug Kit 26.5 25F71's .kdk directory"
for t in git jq shasum; do command -v $t >/dev/null || die "no $t"; done
[ -z "$SERIAL$FLASH" ] || command -v "${ADB:-adb}" >/dev/null || die "no adb (Android platform-tools; ADB=<path>)"
mkdir -p "$WORK" "$OUT"; WORK=$(cd "$WORK" && pwd); OUT=$(cd "$OUT" && pwd)
LOG=$OUT/build-ios27.log; exec > >(tee -a "$LOG") 2>&1
echo "build-ios27: $(date -u +%FT%TZ), kernel repository $REF, work $WORK, out $OUT"

step "0. the kernel repository at $REF"
K=$WORK/scion-kernel
[ -d "$K/.git" ] || git clone -q "$KERNEL27_REPO" "$K"
git -C "$K" fetch -q origin
git -C "$K" checkout -q --detach "$(git -C "$K" rev-parse --verify "origin/$REF^{commit}" 2>/dev/null || echo "$REF")"
REV=$(git -C "$K" rev-parse HEAD); echo "scion-kernel $REV"
. "$K/tools/ios27/builds/build-conf.sh"
BUILD=${IOS27_BUILD:-$(ios27_build_default)}
ios27_build_check "$BUILD" || die "build $BUILD: no tools/ios27/builds/$BUILD.conf at $REV"
WANT_NAME=$(ios27_build_get "$BUILD" IPSW_NAME); WANT_SIZE=$(ios27_build_get "$BUILD" IPSW_SIZE)
WANT_VER=$(ios27_build_get "$BUILD" VERSION); WANT_PROD=$(ios27_build_get "$BUILD" PRODUCT)
if [ -z "${PY:-}" ]; then
	[ -x "$WORK/venv/bin/python3" ] || { python3 -m venv "$WORK/venv" && "$WORK/venv/bin/pip" -q install numpy ziglang; }
	PY=$WORK/venv/bin/python3
fi
export PY DEVELOPER_DIR IOS27_BUILD=$BUILD
"$PY" -c 'import numpy, ziglang' 2>/dev/null || die "PY=$PY has no numpy or ziglang (pip install numpy ziglang)"

step "1. the IPSW: iOS $WANT_VER ($BUILD) for $WANT_PROD"
[ "$(basename "$IPSW")" = "$WANT_NAME" ] || echo "NOTE: the file is named $(basename "$IPSW"), Apple's name is $WANT_NAME"
got=$(stat -f %z "$IPSW"); [ "$got" = "$WANT_SIZE" ] || die "$IPSW is $got bytes; $WANT_NAME is $WANT_SIZE"
"$PY" - "$IPSW" "$WANT_VER" "$BUILD" "$WANT_PROD" <<'PY' || die "the IPSW's BuildManifest is not iOS $WANT_VER ($BUILD) for $WANT_PROD"
import plistlib, sys, zipfile
ipsw, ver, build, prod = sys.argv[1:]
m = plistlib.loads(zipfile.ZipFile(ipsw).read('BuildManifest.plist'))
ok = m.get('ProductVersion') == ver and m.get('ProductBuildVersion') == build and prod in m.get('SupportedProductTypes', [])
print('BuildManifest: iOS %s (%s) for %s' % (m.get('ProductVersion'), m.get('ProductBuildVersion'), ', '.join(m.get('SupportedProductTypes', []))))
sys.exit(0 if ok else 1)
PY
if [ "$SKIP_HASH" = 0 ]; then
	sum=$(shasum -a 256 "$IPSW" | cut -c1-64); echo "SHA-256 $sum"
	want=$(ios27_build_get "$BUILD" IPSW_SHA256)
	[ -z "$want" ] || [ "$want" = "$sum" ] || die "the IPSW's SHA-256 is $sum, Apple's is $want"
	[ -n "$want" ] || echo "NOTE: $BUILD.conf records no SHA-256 to compare with: size and manifest checked"
fi

step "2. the kernel"
if [ -n "$KERNEL" ]; then cp "$KERNEL" "$K/hakios-kernel"; echo "given: $KERNEL"
else (cd "$K" && OS_PROFILE=ios-27 make kernel JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"); fi
[ -f "$K/hakios-kernel" ] || die "no hakios-kernel"
echo "kernel $(shasum -a 256 "$K/hakios-kernel" | cut -c1-16)"

step "3. your inputs from the IPSW"
IN=$K/inputs
if [ -n "$INPUTS" ]; then
	grep -q "build $BUILD\$" "$INPUTS/SOURCE.txt" || die "--inputs $INPUTS were made from another build than $BUILD"
	rm -rf "$IN"; cp -Rc "$INPUTS" "$IN" 2>/dev/null || cp -R "$INPUTS" "$IN"
	(cd "$IN" && grep -E '^[0-9a-f]{64}  ' SOURCE.txt | shasum -a 256 -c -) || die "--inputs: a file differs from SOURCE.txt's SHA-256"
else
	(cd "$K" && tools/ios27/s9/fetch-apple-inputs.sh "$IPSW" inputs)
fi
[ -f "$IN/n104ap.adt" ] || die "no inputs/n104ap.adt"

step "4. the loader and the boot image"
if [ -z "$TEMPLATE" ]; then
	TEMPLATE=$OUT/recovery-template.img
	"$K/tools/ios27/s9/flash.sh" "$SERIAL" pull-template "$TEMPLATE"
fi
# the S9's device repository (its firmware's sums): make-boot-image.sh puts the sensor hub's image in the device tree
(cd "$K" && python3 tools/hakios-device.py sync starlte)
(cd "$K" && tools/ios27/s9/build-loader.sh)
REC=(); [ -n "$OVERLAY" ] || REC=(--inject-record none)
(cd "$K" && tools/ios27/s9/make-boot-image.sh --kernel hakios-kernel --donor-adt inputs/n104ap.adt --template "$TEMPLATE" \
	"${REC[@]}" --out "$OUT/xnu-boot-ios27.img")
if [ -z "$OVERLAY" ]; then
	(cd "$OUT" && shasum -a 256 xnu-boot-ios27.img > SHA256SUMS)
	echo; echo "build-ios27: boot image made: $OUT/xnu-boot-ios27.img ($(cut -c1-16 "$OUT/SHA256SUMS"))."
	[ "$DRY" = 1 ] && echo "--dry-run: stopped before the root and before any phone." ||
		echo "No --overlay: the root (INSTALL-S9.md sections 4 and 5) was not built and nothing was written to a phone."
	exit 0
fi

step "5. the root image (sudo)"
mnt=$(mktemp -d /tmp/sysos.XXXXXX)
hdiutil attach -readonly -nobrowse -imagekey diskimage-class=CRawDiskImage -mountpoint "$mnt" "$IN/systemos.dmg" >/dev/null
rc=0; (cd "$K" && tools/ios27/s9/prepare-root-inputs.sh "$mnt/System/Library/Caches/com.apple.dyld" "$OVERLAY") || rc=$?
hdiutil detach "$mnt" >/dev/null || true; rmdir "$mnt" 2>/dev/null || true
[ "$rc" = 0 ] || die "prepare-root-inputs.sh failed"
sudo IOS27_BUILD="$BUILD" PY="$PY" DEVELOPER_DIR="$DEVELOPER_DIR" OUT="$OUT/root-full.img" "$K/tools/ios27/s9/build-root.sh" "$IN"
[ -f "$OUT/root-full.img" ] && [ -f "$OUT/root-full.img.inject" ] || die "no root image (and its .inject record) in $OUT"
# the boot image again, with the root's record of injected libraries (they must agree)
(cd "$K" && tools/ios27/s9/make-boot-image.sh --kernel hakios-kernel --donor-adt inputs/n104ap.adt --template "$TEMPLATE" \
	--inject-record "$OUT/root-full.img.inject" --out "$OUT/xnu-boot-ios27.img")
(cd "$OUT" && shasum -a 256 xnu-boot-ios27.img root-full.img > SHA256SUMS)

if [ -z "$FLASH" ]; then
	echo; echo "build-ios27: done, nothing written to a phone. To install (the phone in TWRP; ERASES Android's data):"
	echo "  $K/tools/ios27/s9/flash.sh SERIAL root $OUT/root-full.img"
	echo "  $K/tools/ios27/s9/flash.sh SERIAL boot $OUT/xnu-boot-ios27.img reboot"
	exit 0
fi
step "6. install on $FLASH (BOOT and USERDATA only, each read back)"
"$K/tools/ios27/s9/flash.sh" "$FLASH" info
"$K/tools/ios27/s9/flash.sh" "$FLASH" backup-boot "$OUT/android-boot-$FLASH.img"
"$K/tools/ios27/s9/flash.sh" "$FLASH" root "$OUT/root-full.img"
"$K/tools/ios27/s9/flash.sh" "$FLASH" boot "$OUT/xnu-boot-ios27.img" reboot
echo "build-ios27: installed. The way back: $OUT/android-boot-$FLASH.img (flash.sh $FLASH boot ...) and TWRP."
