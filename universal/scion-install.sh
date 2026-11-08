#!/bin/sh
# SPDX-License-Identifier: MIT
# scion-install.sh: Scion's verified install for the Exynos 9810 Galaxys (S9 starlte, S9+ star2lte, Note9 crownlte), run from
# TWRP's terminal (adb shell, or Advanced > Terminal) against a zip universal/mkinstaller.sh made. It is a second way in beside
# update-binary, which it does not replace and does not change. TWRP stays where it is: RECOVERY is never written.
#
#   sh scion-install.sh --zip ZIP [--mode kernel-update|full] [--apply] [--log FILE] [--expect-device starlte|star2lte|crownlte]
#                       [--zip-sha256 HEX] [--backup-dir DIR]
#   sh scion-install.sh --print-manifest starlte|star2lte|crownlte
#
#   --mode kernel-update   (the default) writes BOOT, and nothing else. The system image must already be on the phone: SYSTEM is
#                          read and its SHA-256 compared with the image this zip was made with, and a phone whose SYSTEM is
#                          something else (Android, an older build) is refused, with what to do. BOOT is copied to RAM first and
#                          put back if what was written does not read back right.
#   --mode full            writes SYSTEM (the iOS system image, from the zip) and then BOOT. The zip's members are checked by
#                          their SHA-256 before the first write. SYSTEM has no copy to go back to: restore your TWRP backup.
#   --apply                without it nothing is written, anywhere: it is a dry run that does every check and says what it would
#                          write. A dry run is the default, and it is the thing to share first (its log).
#   --log FILE             the log (default /tmp/scion-install-DATE.log; a copy goes to /sdcard when that is writable). It lists
#                          what was looked at and decided, with the partition table it saw, so that you can send it to us.
#   --expect-device NAME   refuse unless the phone is this one (a second look, if you have several phones' zips)
#   --zip-sha256 HEX       the zip's own SHA-256, from the .sha256 file build-installer.sh wrote: refuse a zip that differs
#   --backup-dir DIR       where BOOT's copy goes (default /tmp, TWRP's RAM disk)
#
# Written, only with --apply, only these: BOOT; and SYSTEM in --mode full. USERDATA is on the allow-list in the sense that it is
# the only other partition Scion's installers ever format, but this script never does: a zip made with mkinstaller.sh -U and
# update-binary does that. EFS, SEC_EFS, CPEFS, RADIO, CP_DEBUG, RECOVERY, PARAM, UP_PARAM, PERSISTENT, STEADY, BOTA0/1, DTB,
# DTBO, KEYSTORAGE, NAD_REFER, RPMB, TIMA and the boot chain are refused by name and by the block device their names resolve
# to. RECOVERY's and EFS's SHA-256 are taken before and after, and a change is reported as a failure.
#
# Every check comes before the first write; a refusal says what to do. The images are the user's own build, from the user's own
# IPSW: the zip carries them, this script carries nothing of Apple's, Samsung's or anyone's.
#
# Nothing here has been run on a phone. tools/test_scion_install.py runs it on a computer against fake partition files.
# Test hooks (SCION_TEST_*, below) exist only for that.

set -u
VERSION=1
PROP_OFF=50             # 30 bytes of local header + "scion/installer.prop" (20): as update-binary
PROP_SIZE=4096
BS=4096

ZIP='' MODE=kernel-update APPLY=0 LOG='' EXPECT='' ZIPSHA='' BACKUP_DIR=${TMPDIR:-/tmp} PRINT=''
WRITTEN="Nothing was written."
WORK=''
SHARE_DIR=${SCION_SHARE_DIR:-/sdcard}

usage() { sed -n 2,35p "$0"; }
# TWRP's shell (mksh) counts in 32 bits, in $(( )) and in test alike: every size goes through awk (as update-binary does)
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'; }
mb() { awk -v a="$1" 'BEGIN { printf "%.0f", int(a / 1048576) }'; }
plus1() { awk -v a="$1" 'BEGIN { printf "%.0f", a + 1 }'; }
rest() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.0f", a - b * int(a / b) }'; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
ishex64() { [ "${#1}" = 64 ] && case "$1" in *[!0-9a-f]*) return 1 ;; esac; }
sha256() { if command -v sha256sum > /dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

while [ $# -gt 0 ]; do
	case "$1" in
	--zip) [ $# -ge 2 ] || { echo "scion-install.sh: --zip needs a file" >&2; exit 2; }; ZIP=$2; shift 2 ;;
	--mode) [ $# -ge 2 ] || { echo "scion-install.sh: --mode needs kernel-update or full" >&2; exit 2; }; MODE=$2; shift 2 ;;
	--apply) APPLY=1; shift ;;
	--log) [ $# -ge 2 ] || { echo "scion-install.sh: --log needs a file" >&2; exit 2; }; LOG=$2; shift 2 ;;
	--expect-device) [ $# -ge 2 ] || { echo "scion-install.sh: --expect-device needs a name" >&2; exit 2; }; EXPECT=$2; shift 2 ;;
	--zip-sha256) [ $# -ge 2 ] || { echo "scion-install.sh: --zip-sha256 needs a hex string" >&2; exit 2; }; ZIPSHA=$2; shift 2 ;;
	--backup-dir) [ $# -ge 2 ] || { echo "scion-install.sh: --backup-dir needs a directory" >&2; exit 2; }; BACKUP_DIR=$2; shift 2 ;;
	--print-manifest) [ $# -ge 2 ] || { echo "scion-install.sh: --print-manifest needs a phone" >&2; exit 2; }; PRINT=$2; shift 2 ;;
	-h|--help) usage; exit 0 ;;
	*) echo "scion-install.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

# ---- the per-device manifests: what each phone's partition table must look like before anything is written ----------------
# REQUIRED   names that must resolve through by-name, each to a different block device (a name that is missing, or two names
#            on one device, is a phone this was not made for, or a table that was changed under it)
# SYSTEM     the partition the system image goes to (a zip that names another is refused)
# *_EXACT    the partition's size in bytes when someone has read it on that phone (empty: not recorded yet)
# *_MIN/MAX  sanity bounds, NOT measurements: a partition outside them is refused, as it is probably not the one meant. They
#            are wide on purpose. The exact sizes are filled in from the first dry runs' logs, which print what was found.
# The three phones share a layout as far as anyone here knows (Samsung's UFS table for the Exynos 9810); each has its own entry
# so that a phone's real numbers go in its own entry without touching the others.
manifest() { # PHONE: sets M_*; returns 1 for a phone without a manifest
	M_REQUIRED="BOOT RECOVERY EFS SYSTEM USERDATA"
	M_SYSTEM=SYSTEM
	M_BOOT_EXACT='' M_SYSTEM_EXACT=''
	M_BOOT_MIN=4194304 M_BOOT_MAX=268435456              # 4 MiB .. 256 MiB: a boot image's room, not a data partition's
	M_SYSTEM_MIN=1073741824 M_SYSTEM_MAX=17179869184     # 1 GiB .. 16 GiB
	M_WATCH="RECOVERY EFS"                               # read before and after, never written
	case "$1" in
	starlte) M_TITLE="Galaxy S9 (SM-G960F)" ;;
	star2lte) M_TITLE="Galaxy S9+ (SM-G965F)" ;;
	crownlte) M_TITLE="Galaxy Note9 (SM-N960F)" ;;
	*) return 1 ;;
	esac
}
# the names never written, whatever the zip says (and the block devices they resolve to, below)
NEVER_NAMES="EFS SEC_EFS CPEFS RADIO CP_DEBUG RECOVERY PARAM UP_PARAM PERSISTENT STEADY BOTA0 BOTA1 DTB DTBO KEYSTORAGE NAD_REFER RPMB TIMA UH SBOOT BL2 ECT CM"
is_never_name() { for n in $NEVER_NAMES; do [ "$n" = "$1" ] && return 0; done; return 1; }

if [ -n "$PRINT" ]; then
	manifest "$PRINT" || { echo "scion-install.sh: no manifest for $PRINT (starlte, star2lte, crownlte)" >&2; exit 2; }
	echo "manifest $PRINT: $M_TITLE"
	echo "  required partitions: $M_REQUIRED"
	echo "  system image goes to: $M_SYSTEM"
	echo "  BOOT: exact ${M_BOOT_EXACT:-not recorded}, sanity $M_BOOT_MIN..$M_BOOT_MAX bytes"
	echo "  $M_SYSTEM: exact ${M_SYSTEM_EXACT:-not recorded}, sanity $M_SYSTEM_MIN..$M_SYSTEM_MAX bytes"
	echo "  read before and after, never written: $M_WATCH"
	echo "  never written: $NEVER_NAMES"
	exit 0
fi

# ---- the log ----------------------------------------------------------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S 2> /dev/null || echo now)
[ -n "$LOG" ] || LOG=${SCION_LOG_DIR:-/tmp}/scion-install-$TS.log
: > "$LOG" 2> /dev/null || { echo "scion-install.sh: cannot write the log $LOG (--log FILE)" >&2; exit 2; }
say() { echo "$*"; echo "$*" >> "$LOG"; }
note() { echo "$*" >> "$LOG"; }
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
finish() { # EXIT_CODE
	cleanup
	if [ -d "$SHARE_DIR" ] && [ -w "$SHARE_DIR" ] && [ "$(cd "$(dirname "$LOG")" && pwd)" != "$(cd "$SHARE_DIR" && pwd)" ]; then
		cp "$LOG" "$SHARE_DIR/scion-install-$TS.log" 2> /dev/null && echo "log: $LOG (a copy: $SHARE_DIR/scion-install-$TS.log)" && exit "$1"
	fi
	echo "log: $LOG"
	exit "$1"
}
die() { # WHY [WHAT TO DO]
	say "REFUSED: $1"
	[ -z "${2:-}" ] || say "  what to do: $2"
	say "$WRITTEN"
	echo "RESULT: refused" >> "$LOG"
	finish 1
}
fail() { # something went wrong after a write
	say "FAILED: $1"
	[ -z "${2:-}" ] || say "  what to do: $2"
	say "$WRITTEN"
	echo "RESULT: failed" >> "$LOG"
	finish 1
}

say "scion-install.sh $VERSION: $( [ "$APPLY" = 1 ] && echo 'APPLY' || echo 'dry run (nothing will be written; --apply writes)' ), mode $MODE"
note "date: $TS; zip: $ZIP"
case "$MODE" in kernel-update|full) ;; *) die "--mode $MODE: kernel-update or full" ;; esac
[ -n "$ZIP" ] || die "--zip ZIP is required" "give the installer zip build-installer.sh made, e.g. --zip /sdcard/scion-exynos9810-installer.zip"
[ -f "$ZIP" ] && [ -r "$ZIP" ] || die "$ZIP is not a readable file"
case "$BACKUP_DIR" in *' '*) die "--backup-dir has a space in it" ;; esac
WORK=$(mktemp -d "${TMPDIR:-/tmp}/scion-install.XXXXXX" 2> /dev/null) || { WORK=/tmp/scion-install.$$; mkdir -p "$WORK" || die "no place for scratch files"; }
trap cleanup EXIT

# ---- the zip and its installer.prop ----------------------------------------------------------------------------------------
zip_bytes=$(wc -c < "$ZIP" | tr -d ' ')
[ "$(dd if="$ZIP" bs=1 count=2 2> /dev/null)" = PK ] || die "$ZIP is not one of Scion's installer zips (no zip header)" "build it again, or copy it again: adb push"
[ "$(dd if="$ZIP" bs=1 skip=30 count=20 2> /dev/null)" = "scion/installer.prop" ] || die "$ZIP is not one of Scion's installer zips (no scion/installer.prop first)" "build it again with build-installer.sh"
PROPF=$WORK/installer.prop
tail -c +"$(plus1 "$PROP_OFF")" "$ZIP" | head -c "$PROP_SIZE" > "$PROPF"
pget() { sed -n "s/^$1=\\(.*\\)\$/\\1/p" "$PROPF" | head -1 | sed 's/^"//; s/"$//'; }
# the prop is read as data, never run as shell (update-binary sources it): every value is checked for the shape it must have
INSTALLER=$(pget SCION_INSTALLER)
case "$INSTALLER" in 2|3) ;; *) die "this zip's installer.prop is not one of universal/mkinstaller.sh's (SCION_INSTALLER=$INSTALLER)" "make the zip again with this repository's universal/mkinstaller.sh" ;; esac
SYSTEM_PART=$(pget SYSTEM_PART)
SYSTEM_OFF=$(pget SYSTEM_OFF) SYSTEM_SIZE=$(pget SYSTEM_SIZE) SYSTEM_SHA256=$(pget SYSTEM_SHA256)
DEVICES=$(pget DEVICES) BUILD=$(pget SCION_BUILD) FORMAT_USERDATA=$(pget FORMAT_USERDATA)
case "$SYSTEM_PART" in ''|*[!A-Za-z0-9_]*) die "this zip's installer.prop names a system partition that is not a name ($SYSTEM_PART)" ;; esac
isnum "$SYSTEM_OFF" && isnum "$SYSTEM_SIZE" && ishex64 "$SYSTEM_SHA256" || die "this zip's installer.prop has no usable system image entry" "make the zip again with universal/mkinstaller.sh"
case "$DEVICES" in ''|*[!a-z0-9\ ]*) die "this zip's installer.prop has no usable device list ($DEVICES)" ;; esac
note "zip: $zip_bytes bytes; installer.prop version $INSTALLER; build: $BUILD"
note "system part: $SYSTEM_PART, image $SYSTEM_SIZE bytes, sha256 $SYSTEM_SHA256; devices: $DEVICES"
if [ -n "$ZIPSHA" ]; then
	ishex64 "$ZIPSHA" || die "--zip-sha256 is not 64 lower-case hex digits"
	say "checking the zip's own SHA-256 (a few minutes with the system image in it)"
	got=$(sha256 < "$ZIP")
	[ "$got" = "$ZIPSHA" ] || die "the zip's SHA-256 is $got, not $ZIPSHA" "the copy on the phone is damaged, or not the one that was built: adb push it again, and compare with the .sha256 file"
	say "  the zip is the one that was built"
fi
region() { tail -c +"$(plus1 "$1")" "$ZIP" | head -c "$2"; }       # LENGTH bytes from OFFSET of the zip

# ---- which phone ----------------------------------------------------------------------------------------------------------
GETPROP=${SCION_TEST_GETPROP:-getprop}
gp() { "$GETPROP" "$1" 2> /dev/null; }
bootloader=$(gp ro.boot.bootloader); [ -n "$bootloader" ] || bootloader=$(gp ro.bootloader)
model=$(gp ro.product.model); [ -n "$model" ] || model=$(gp ro.product.vendor.model)
device=$(gp ro.product.device); [ -n "$device" ] || device=$(gp ro.product.vendor.device)
say "this phone: boot loader \"$bootloader\", model \"$model\", device \"$device\""
by_id() { # a boot loader id or a model without SM- -> the phone; the Korean models are not taken (their boards were never read)
	case "$1" in
	G960F*) echo starlte ;; G965F*) echo star2lte ;; N960F*) echo crownlte ;;
	G960N*|G965N*|N960N*) echo korean ;;
	'') ;;
	*) echo unknown ;;
	esac
}
from_bl=$(by_id "$bootloader")
from_id=
case "$model" in
SM-*) from_model=$(by_id "${model#SM-}"); from_id=$from_model ;;
"Galaxy S9") from_model=starlte ;;
"Galaxy S9+"|"Galaxy S9 Plus") from_model=star2lte ;;
"Galaxy Note9"|"Galaxy Note 9") from_model=crownlte ;;
Galaxy*|GALAXY*|galaxy*) from_model=unknown ;;
*) from_model= ;;
esac
case "$device" in
starlte|starltexx|starltekor) from_dev=starlte ;;
star2lte|star2ltexx|star2ltekor) from_dev=star2lte ;;
crownlte|crownltexx|crownltekor) from_dev=crownlte ;;
'') from_dev= ;;
*) from_dev=unknown ;;
esac
PHONE=
for f in "$from_bl" "$from_model" "$from_dev"; do
	case "$f" in
	'') ;;
	korean) die "a Korean model: this installer was not made for it" "use update-binary's zip made with mkinstaller.sh -N, or do not install here" ;;
	unknown) die "not a Galaxy S9, S9+ or Note9 (SM-G960F/FD, SM-G965F/FD, SM-N960F/FD)" "this is the wrong phone for this zip: nothing was changed" ;;
	*) [ -z "$PHONE" ] || [ "$PHONE" = "$f" ] || die "the boot loader, model and device name disagree on which phone this is" "reboot TWRP and run again; if it persists, send the log"
	   PHONE=$f ;;
	esac
done
[ -n "$from_bl$from_id" ] || die "this recovery gives neither the boot loader's id nor an SM- model: cannot tell which phone this is" "use the official TWRP for the phone, or send the log"
[ -z "$EXPECT" ] || [ "$EXPECT" = "$PHONE" ] || die "this is a $PHONE, and --expect-device says $EXPECT" "you have another phone's zip, or the wrong phone connected"
manifest "$PHONE" || die "no manifest for $PHONE"
say "  -> $M_TITLE ($PHONE)"
case " $DEVICES " in *" $PHONE "*) ;; *) die "this zip has no image for the $PHONE (it was made for: $DEVICES)" "make the zip again with -k $PHONE=KERNEL (build-installer.sh --device $PHONE)" ;; esac
KEY=$(echo "$PHONE" | tr a-z A-Z)
BOOT_OFF=$(pget "BOOT_${KEY}_OFF") BOOT_SIZE=$(pget "BOOT_${KEY}_SIZE") BOOT_SHA256=$(pget "BOOT_${KEY}_SHA256")
BOOT_ARGS=$(pget "BOOT_${KEY}_ARGS")
isnum "$BOOT_OFF" && isnum "$BOOT_SIZE" && ishex64 "$BOOT_SHA256" || die "this zip's installer.prop has no usable boot image entry for the $PHONE" "make the zip again with universal/mkinstaller.sh"
note "boot image: $BOOT_SIZE bytes at $BOOT_OFF, sha256 $BOOT_SHA256"
say "  its boot-args: $BOOT_ARGS"
is_never_name "$SYSTEM_PART" && die "this zip would write its system image to $SYSTEM_PART, a partition this installer never writes" "do not use this zip; make one again with the default -p"
[ "$SYSTEM_PART" = "$M_SYSTEM" ] || die "this zip would write its system image to $SYSTEM_PART, and the $PHONE's manifest says $M_SYSTEM" "make the zip again with the default -p; Scion's installer writes SYSTEM only"
[ "$FORMAT_USERDATA" != 1 ] || say "  (this zip also formats USERDATA when flashed by update-binary; this script never does)"

# ---- the partition table this phone has, against its manifest ----------------------------------------------------------------
BYNAME_DIRS=${SCION_TEST_BYNAME:-"/dev/block/by-name /dev/block/platform/*/by-name /dev/block/bootdevice/by-name"}
part() { # a partition by its name, wherever this recovery keeps the names
	for d in $BYNAME_DIRS; do
		[ -e "$d/$1" ] && { readlink -f "$d/$1"; return 0; }
	done
	return 1
}
isblock() { [ -b "$1" ] || { [ "${SCION_TEST_FILES:-}" = 1 ] && [ -f "$1" ]; }; }
devsize() { if [ "${SCION_TEST_FILES:-}" = 1 ]; then wc -c < "$1" | tr -d ' '; else blockdev --getsize64 "$1"; fi; }
getdev() { # NAME: its device in GD, or a refusal (not in a $( ): the refusal has to reach the screen)
	GD=$(part "$1") || die "this phone has no partition named $1" "this is not the partition table the $PHONE's manifest expects: send the log"
}
say "the partition table, against the $PHONE's manifest:"
SEEN=
for n in $M_REQUIRED; do
	getdev "$n"; d=$GD
	isblock "$d" || die "$n resolves to $d, which is not a block device"
	s=$(devsize "$d") && isnum "$s" || die "cannot read $n's size ($d)"
	[ "$(rest "$s" $BS)" = 0 ] && ! le "$s" 0 || die "$n ($d) is $s bytes, not a whole number of $BS-byte blocks"
	for o in $SEEN; do [ "${o#*=}" != "$d" ] || die "$n and ${o%%=*} are the same block device ($d)" "the partition table is not what the manifest expects: nothing was changed"; done
	SEEN="$SEEN $n=$d"
	say "  $n -> $d, $s bytes ($(mb "$s") MB)"
	eval "DEV_$n=\$d SIZE_$n=\$s"
done
# every never-written name that resolves, so that a target on the same device under another name is caught
NEVERDEVS=
for n in $NEVER_NAMES; do
	if d=$(part "$n"); then NEVERDEVS="$NEVERDEVS $d"; note "  never written: $n -> $d"; fi
done
check_target() { # NAME DEVICE: may the installer write this, in this mode?
	if is_never_name "$1"; then die "$1 is a partition this installer never writes"; fi
	case "$MODE:$1" in
	kernel-update:BOOT|full:BOOT|full:SYSTEM) ;;
	*) die "$1 is not on the write allow-list for --mode $MODE (kernel-update: BOOT; full: BOOT and SYSTEM)" ;;
	esac
	for p in $NEVERDEVS; do [ "$p" != "$2" ] || die "$1 resolves to $2, which is a partition that is never written (by another name)" "the partition table is not what the manifest expects: nothing was changed"; done
	isblock "$2" || die "$1 ($2) is not a block device"
}
check_target BOOT "$DEV_BOOT"
[ "$MODE" != full ] || check_target "$M_SYSTEM" "$DEV_SYSTEM"
if [ -n "$M_BOOT_EXACT" ]; then [ "$SIZE_BOOT" = "$M_BOOT_EXACT" ] || die "BOOT is $SIZE_BOOT bytes, the manifest says $M_BOOT_EXACT" "this is not the phone's usual table: send the log"; fi
le "$M_BOOT_MIN" "$SIZE_BOOT" && le "$SIZE_BOOT" "$M_BOOT_MAX" || die "BOOT is $SIZE_BOOT bytes, outside $M_BOOT_MIN..$M_BOOT_MAX: it is probably not the boot partition" "send the log"
le "$BOOT_SIZE" "$SIZE_BOOT" || die "the boot image ($BOOT_SIZE bytes) does not fit BOOT ($SIZE_BOOT)" "build a smaller image, or send the log"
if [ -n "$M_SYSTEM_EXACT" ]; then [ "$SIZE_SYSTEM" = "$M_SYSTEM_EXACT" ] || die "$M_SYSTEM is $SIZE_SYSTEM bytes, the manifest says $M_SYSTEM_EXACT" "send the log"; fi
le "$M_SYSTEM_MIN" "$SIZE_SYSTEM" && le "$SIZE_SYSTEM" "$M_SYSTEM_MAX" || die "$M_SYSTEM is $SIZE_SYSTEM bytes, outside $M_SYSTEM_MIN..$M_SYSTEM_MAX: it is probably not the system partition" "send the log"
le "$SYSTEM_SIZE" "$SIZE_SYSTEM" || die "the system image ($SYSTEM_SIZE bytes) does not fit $M_SYSTEM ($SIZE_SYSTEM)" "send the log"
say "  checked: names, sizes, no partition twice, nothing to be written resolves to a protected one"

# ---- the images, by hash, before any write -------------------------------------------------------------------------------
say "the boot image, by SHA-256:"
got=$(region "$BOOT_OFF" "$BOOT_SIZE" | sha256)
[ "$got" = "$BOOT_SHA256" ] || die "the boot image in the zip reads $got, the zip says $BOOT_SHA256" "the zip is damaged: adb push it again (compare its SHA-256 with the .sha256 file), or build it again"
say "  right ($BOOT_SHA256); the small root and the firmware in it are part of that image"
note "  (the S9's firmware is fetched at build time against pinned sums, userland/build.sh; it is in BOOT's small root, so this hash covers it)"
if [ "$MODE" = full ]; then
	[ "$INSTALLER" = 2 ] && [ "$SYSTEM_OFF" != 0 ] || die "this zip has no system image (it was made for kernel updates)" "use --mode kernel-update, or the full zip"
	say "the system image in the zip, by SHA-256 (a few minutes):"
	got=$(region "$SYSTEM_OFF" "$SYSTEM_SIZE" | sha256)
	[ "$got" = "$SYSTEM_SHA256" ] || die "the system image in the zip reads $got, the zip says $SYSTEM_SHA256" "the zip is damaged: adb push it again (compare its SHA-256 with the .sha256 file), or build it again"
	say "  right ($SYSTEM_SHA256)"
else
	say "SYSTEM on the phone, by SHA-256 (a minute or two; it is only read):"
	got=$(head -c "$SYSTEM_SIZE" "$DEV_SYSTEM" | sha256)
	if [ "$got" != "$SYSTEM_SHA256" ]; then
		note "  SYSTEM reads $got, this zip's image is $SYSTEM_SHA256"
		die "SYSTEM on this phone is not the iOS system image this kernel was built with" "install the full zip first (--mode full, or update-binary in TWRP), or use a kernel-update zip made together with the system image that is on the phone"
	fi
	say "  SYSTEM is the system image this boot image was made with"
fi

# ---- RECOVERY (TWRP) and EFS, as they are now -------------------------------------------------------------------------------
say "the partitions that stay as they are, by SHA-256 now and after:"
BASE=
for n in $M_WATCH; do
	getdev "$n"; d=$GD
	h=$(head -c "$(devsize "$d")" "$d" | sha256)
	BASE="$BASE $n=$h"
	say "  $n ($d): $h"
done

# ---- the plan, and the dry run's end -------------------------------------------------------------------------------------------
say "the plan:"
[ "$MODE" != full ] || say "  SYSTEM $DEV_SYSTEM <- the system image, $SYSTEM_SIZE bytes ($(mb "$SYSTEM_SIZE") MB), checked by SHA-256 as written"
say "  BOOT $DEV_BOOT <- the boot image, $BOOT_SIZE bytes, checked by SHA-256 as written; BOOT's $SIZE_BOOT bytes are copied to $BACKUP_DIR first and put back if it does not read back right"
say "  no other partition is written; RECOVERY and EFS are compared before and after"
if [ "$APPLY" != 1 ]; then
	say "DRY RUN: every check passed, and nothing was written. To write it, run the same command again with --apply."
	echo "RESULT: dry run ok" >> "$LOG"
	finish 0
fi

# ---- apply ---------------------------------------------------------------------------------------------------------------------
BACKUP=$BACKUP_DIR/scion-boot-backup-$TS.img
say "BOOT's copy -> $BACKUP"
head -c "$SIZE_BOOT" "$DEV_BOOT" > "$BACKUP" 2>> "$LOG" || die "cannot copy BOOT to $BACKUP" "free some space there, or give --backup-dir"
BACKUP_SHA=$(sha256 < "$BACKUP")
again=$(head -c "$SIZE_BOOT" "$DEV_BOOT" | sha256)
[ "$again" = "$BACKUP_SHA" ] && [ "$(wc -c < "$BACKUP" | tr -d ' ')" = "$SIZE_BOOT" ] || { rm -f "$BACKUP"; die "BOOT's copy does not match BOOT (the copy is short, or BOOT changes while it is read)" "nothing was written; try again"; }
say "  BOOT's copy: sha256 $BACKUP_SHA"

write_member() { # OFFSET LENGTH DEVICE: copy from the zip
	region "$1" "$2" | dd of="$3" bs=$BS conv=notrunc 2>> "$LOG"
	sync
}
if [ "$MODE" = full ]; then
	say "SYSTEM <- the system image (a few minutes; there is no copy of SYSTEM to go back to)"
	WRITTEN="SYSTEM may be partly written: restore your TWRP backup of SYSTEM and BOOT before booting."
	[ "${SCION_TEST_FILES:-}" = 1 ] || for m in /system /system_root /mnt/system /vendor; do umount "$m" 2> /dev/null; done
	write_member "$SYSTEM_OFF" "$SYSTEM_SIZE" "$DEV_SYSTEM"
	got=$(head -c "$SYSTEM_SIZE" "$DEV_SYSTEM" | sha256)
	[ "$got" = "$SYSTEM_SHA256" ] || fail "SYSTEM reads back wrong (sha256 $got, want $SYSTEM_SHA256)" "restore your TWRP backup of SYSTEM; BOOT was not written"
	say "  SYSTEM reads back right"
fi
say "BOOT <- the boot image"
WRITTEN="BOOT was written (and its copy is $BACKUP)."
[ "$MODE" != full ] || WRITTEN="SYSTEM and BOOT were written (BOOT's copy is $BACKUP)."
write_member "$BOOT_OFF" "$BOOT_SIZE" "$DEV_BOOT"
got=$(head -c "$BOOT_SIZE" "$DEV_BOOT" | sha256)
if [ "$got" != "$BOOT_SHA256" ]; then
	say "BOOT reads back wrong (sha256 $got, want $BOOT_SHA256): putting its copy back"
	head -c "$SIZE_BOOT" "$BACKUP" | dd of="$DEV_BOOT" bs=$BS conv=notrunc 2>> "$LOG"
	sync
	back=$(head -c "$SIZE_BOOT" "$DEV_BOOT" | sha256)
	if [ "$back" = "$BACKUP_SHA" ]; then
		WRITTEN="BOOT is back as it was (its copy matches); nothing else of BOOT's was changed.$( [ "$MODE" = full ] && echo ' SYSTEM was written: restore your TWRP backup of SYSTEM.')"
		fail "the boot image read back wrong, and BOOT is back as it was" "run again; if it fails again, send the log (the partition may be failing)"
	fi
	WRITTEN="BOOT is neither the new image nor its copy: flash the stock BOOT from Download mode (Odin/heimdall). The copy is $BACKUP."
	fail "the boot image read back wrong, and putting BOOT's copy back failed too" "do not reboot into Android: flash BOOT from Download mode; the copy of BOOT is $BACKUP"
fi
say "  BOOT reads back right"

say "RECOVERY and EFS, after:"
for b in $BASE; do
	n=${b%%=*} want=${b#*=}
	getdev "$n"; d=$GD
	h=$(head -c "$(devsize "$d")" "$d" | sha256)
	if [ "$h" != "$want" ]; then fail "$n changed during the install (sha256 $h, was $want)" "do not reboot: send the log; this installer never writes $n, so something else did"; fi
	say "  $n unchanged"
done
rm -f "$BACKUP"
say "Done. BOOT$( [ "$MODE" = full ] && echo ' and SYSTEM') written and read back by SHA-256; TWRP (RECOVERY) is as it was. Reboot > System starts Scion."
say "Android back: restore your BOOT$( [ "$MODE" = full ] && echo ' and SYSTEM') backups in TWRP."
echo "RESULT: ok" >> "$LOG"
finish 0
