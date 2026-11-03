#!/bin/bash
# One TWRP installer for the Exynos 9810 Galaxys: the S9 (SM-G960F, starlte), the S9+ (SM-G965F, star2lte) and the Note9
# (SM-N960F, crownlte). The zip carries a boot image for each phone it was made for and one iOS system image; in TWRP it
# finds out which phone it is on (update-binary: the boot loader's id, the model and the device name must agree), refuses
# any other, and writes that phone's boot image to BOOT and the system image to SYSTEM, each read back and checked by
# its SHA-256. It never writes anything else, unless it was made with -U (USERDATA, below).
#
#   universal/mkinstaller.sh -s system.apfs -k DEVICE=KERNEL [-k DEVICE=KERNEL ...] [-K kernel-repo] [-r root.apfs]
#                            [-a DEVICE="boot-args"] [-p PARTITION] [-t SECS] [-N] [-V]
#                            [-U -u DEVICE=BLOCKS ...] [-o installer.zip] [extra boot-args for every phone...]
#
#   -s  the iOS system image (userland/system.apfs of the kernel repo, built from your own IPSW): one for every phone
#   -k  a phone and its kernel (make DEVICE_defconfig && make kernel there, hakios-kernel copied away): one -k a phone;
#       DEVICE is starlte, star2lte or crownlte. The zip installs on the phones it has a kernel for, and no other.
#   -K  the kernel repository, with devices/starlte (and devices/star2lte, devices/crownlte for those) synced; default
#       $SCION_KERNEL, else ../hackios-xnu-kernel beside this repository
#   -r  the small root (ALONE=1 RC=rc.launchd), the same for every phone; default the kernel repo's userland/root.apfs
#   -a  more boot-arguments for one phone only (repeatable), over its defaults
#   -p  the partition the system image goes to (SYSTEM)
#   -t  a test run's seconds, after which the loader keeps the log and restarts into TWRP. Default: 0 (no limit) on the S9,
#       120 on the S9+ and the Note9, which nobody has run this on
#   -N  also accept the Korean models (SM-G960N, G965N, N960N): their boards' device trees were never read, so they
#       are refused unless the zip is made with this
#   -V  verbose: the kernel's log on the screen while it starts
#   -U  the zip also makes /private/var persistent: it formats USERDATA as HFS Plus (THIS ERASES ANDROID'S DATA) and
#       the boot images get ufs_write=1 var_hfs=ufs_USERDATA_data. Needs -u for every size it should handle, and in
#       TWRP it runs only when the zip's file name still contains "format-userdata" (the default -o name does)
#   -u  DEVICE=BLOCKS: a USERDATA of BLOCKS blocks of 4096 on that phone (TWRP: blockdev --getsize64
#       /dev/block/by-name/USERDATA, divided by 4096). The volume is made here (the kernel repo's tools/mkdatavol.py
#       --userdata, with mkfs.hfsplus or macOS's newfs_hfs: MKFS=...); a phone whose USERDATA has another size is told
#       the command to make its own and nothing is written. Repeatable: one per phone and storage size.
#   -o  the zip (out/scion-exynos9810-installer.zip, or ...-format-userdata.zip with -U)
#
# The zip carries iOS's own files, from your IPSW, and the loader carries your iPhone's identity: it is yours to hand on
# privately, never to be published or committed (.gitignore keeps it out of this repository). Nothing of Apple's is in
# this repository: the system image is built from your IPSW, as for starlte/mkinstaller.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KREPO=${SCION_KERNEL:-$REPO/../hackios-xnu-kernel}
SYSTEM= ROOT= PART=SYSTEM SECS= OUT= QUIET=-q KOREAN=0 FORMAT=0
KERNEL_starlte= KERNEL_star2lte= KERNEL_crownlte= EXTRA_starlte= EXTRA_star2lte= EXTRA_crownlte=
UBLOCKS_starlte= UBLOCKS_star2lte= UBLOCKS_crownlte=
get() { eval "echo \"\${$1_$2:-}\""; }        # get KERNEL starlte (no associative arrays: macOS's bash is 3.2)
add_pair() { # NAME VALUE ARRAY
	local dev=${2%%=*} val=${2#*=}
	case "$dev" in starlte|star2lte|crownlte) ;; *) echo "mkinstaller.sh: -$1 $2: the phone is starlte, star2lte or crownlte" >&2; exit 2 ;; esac
	[ "$dev" != "$2" ] || { echo "mkinstaller.sh: -$1 $2: DEVICE=VALUE" >&2; exit 2; }
	case $1 in
	k) printf -v "KERNEL_$dev" %s "$val" ;;
	a) printf -v "EXTRA_$dev" %s "$(get EXTRA "$dev") $val" ;;
	u) case "$val" in *[!0-9]*|'') echo "mkinstaller.sh: -u $2: blocks, a number" >&2; exit 2 ;; esac
	   printf -v "UBLOCKS_$dev" %s "$(get UBLOCKS "$dev") $val" ;;
	esac
}
while getopts s:k:K:r:a:p:t:o:u:NVU opt; do
	case $opt in
	s) SYSTEM=$OPTARG ;; K) KREPO=$OPTARG ;; r) ROOT=$OPTARG ;; p) PART=$OPTARG ;; t) SECS=$OPTARG ;; o) OUT=$OPTARG ;;
	k|a|u) add_pair "$opt" "$OPTARG" ;;
	N) KOREAN=1 ;; V) QUIET= ;; U) FORMAT=1 ;;
	*) sed -n 2,37p "$0"; exit 2 ;;
	esac
done
shift $((OPTIND - 1))
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
[ -n "$SYSTEM" ] || { echo "mkinstaller.sh: -s system.apfs is required" >&2; exit 2; }
[ -n "$KERNEL_starlte$KERNEL_star2lte$KERNEL_crownlte" ] || { echo "mkinstaller.sh: -k DEVICE=KERNEL, at least one" >&2; exit 2; }
[ -n "$OUT" ] || OUT=$REPO/out/scion-exynos9810-installer$(if [ "$FORMAT" = 1 ]; then echo -format-userdata; fi).zip
KREPO=$(cd "$KREPO" && pwd)
SYSTEM=$(abs "$SYSTEM") OUT=$(abs "$OUT") ROOT=$(abs "${ROOT:-$KREPO/userland/root.apfs}")
[ "$(dd if="$SYSTEM" bs=1 skip=32 count=4 2>/dev/null)" = NXSB ] || { echo "mkinstaller.sh: $SYSTEM is not an APFS container" >&2; exit 1; }
[ -f "$ROOT" ] || { echo "mkinstaller.sh: $ROOT is missing" >&2; exit 1; }
case "${SECS:-0}" in *[!0-9]*) echo "mkinstaller.sh: -t $SECS: seconds, a number" >&2; exit 2 ;; esac
case "$PART" in *[!A-Za-z0-9_]*|'') echo "mkinstaller.sh: -p $PART: a partition name, letters, digits and _" >&2; exit 2 ;; esac
# the partitions this installer never writes, whatever it is told (update-binary refuses them again)
case "$PART" in BOOT|RECOVERY|EFS|SEC_EFS|CPEFS|RADIO|CP_DEBUG|PARAM|PERSISTENT|STEADY|USERDATA|BOTA*|DTB*|KEYSTORAGE|NAD_REFER)
	echo "mkinstaller.sh: -p $PART: not a partition for the system image" >&2; exit 2 ;;
esac
if [ "$FORMAT" = 1 ]; then
	[ -n "$UBLOCKS_starlte$UBLOCKS_star2lte$UBLOCKS_crownlte" ] || { echo "mkinstaller.sh: -U needs -u DEVICE=BLOCKS for the USERDATA sizes it formats" >&2; exit 2; }
	case "$(basename "$OUT")" in *format-userdata*) ;; *)
		echo "mkinstaller.sh: -U: the zip's name must contain format-userdata (update-binary checks it again)" >&2; exit 2 ;;
	esac
elif [ -n "$UBLOCKS_starlte$UBLOCKS_star2lte$UBLOCKS_crownlte" ]; then
	echo "mkinstaller.sh: -u without -U: USERDATA is only formatted by a zip made with -U" >&2; exit 2
fi

# The S9's boot-arguments are its defaults, which devices/starlte/mkimage.sh puts on every image (the kernel repository's
# devices/starlte/configs/starlte.config; README.md there, "Defaults"), as for starlte/mkinstaller.sh: nothing is given
# for it here but the system image's partition and -a's.
S9_ARGS=
# The S9+ and the Note9: what is the SoC's and was seen on the S9 with nothing of the board's: the two A55s, the flash
# through the loader, the thermal stop, the log kept for TWRP. No driver of the board's (touch, keys, battery, USB,
# GPU) until someone has seen it on that phone: add them with -a, one at a time (devices/<name>/README.md, "First runs").
UNSEEN_ARGS="cpus=2 bootcpu=2 ufs=2 tmu=3 esslog=1"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/scion-universal.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
MEMBERS=() DEVS=
PROP="# The installer's facts, read by update-binary (sourced: shell assignments only). Made by universal/mkinstaller.sh.
SCION_INSTALLER=2
SYSTEM_PART=$PART
KOREAN=$KOREAN
FORMAT_USERDATA=$FORMAT
SYSTEM_OFF=@SYSTEM_OFF@
SYSTEM_SIZE=@SYSTEM_SIZE@
SYSTEM_SHA256=@SYSTEM_SHA256@
"
for dev in starlte star2lte crownlte; do
	[ -n "$(get KERNEL $dev)" ] || continue
	k=$(abs "$(get KERNEL $dev)")
	[ -f "$k" ] || { echo "mkinstaller.sh: $dev's kernel $k is missing" >&2; exit 1; }
	[ -x "$KREPO/devices/$dev/mkimage.sh" ] || { echo "mkinstaller.sh: $KREPO/devices/$dev is not synced (tools/hakios-device.py sync $dev)" >&2; exit 1; }
	[ "$dev" != starlte ] || grep -q -- '--with' "$KREPO/devices/starlte/mkimage.sh" || {
		echo "mkinstaller.sh: $KREPO/devices/starlte is older than the S9's defaults: tools/hakios-device.py sync starlte" >&2; exit 1; }
	if [ "$dev" = starlte ]; then
		args="$S9_ARGS" secs=${SECS:-0} borrow=
	else
		args="$UNSEEN_ARGS" secs=${SECS:-120} borrow=-U   # the S9's UEFI: devices/<name>/README.md, "The UEFI"
	fi
	# (the S9's defaults already keep /private/var in USERDATA: said again, it changes nothing there)
	[ "$FORMAT" = 1 ] && args="$args ufs_write=1 var_hfs=ufs_USERDATA_data"
	args=$(echo $args system_apfs=ufs_$PART$(get EXTRA $dev) $*)
	echo "mkinstaller.sh: $dev: boot-args $args$([ "$dev" != starlte ] || echo ' (over the S9 defaults)')"
	made=$("$KREPO/devices/$dev/mkimage.sh" $borrow $QUIET -o "$WORK/boot_$dev.img" -k "$k" -r "$ROOT" -s "$secs" $args)
	echo "$made" | sed 's/^/  /'
	# what the image carries, as its mkimage.sh said it (the S9's: its defaults with these over them)
	effective=$(echo "$made" | sed -n 's/^mkimage.sh: boot-args: \(.*\); [^;]*$/\1/p')
	args=${effective:-$args}
	key=$(echo "$dev" | tr a-z A-Z)
	MEMBERS+=("boot_$dev.img=$WORK/boot_$dev.img")
	PROP+="BOOT_${key}_OFF=@BOOT_${key}_OFF@
BOOT_${key}_SIZE=@BOOT_${key}_SIZE@
BOOT_${key}_SHA256=@BOOT_${key}_SHA256@
BOOT_${key}_ARGS=\"$(echo $args | tr -d '"$`\\')\"
"
	DEVS="$DEVS $dev"
	for blocks in $(get UBLOCKS $dev); do
		u="$WORK/ud-$dev-$blocks"
		python3 "$KREPO/tools/mkdatavol.py" --userdata "$blocks" "$u" ${MKFS:-mkfs.hfsplus} | sed 's/^/  /'
		head_blocks=$(sed -n 's/^head: blocks 0\.\.\([0-9]*\) .*/\1/p' "$u/userdata.txt")
		head_sha=$(sed -n 's/^head: .* sha256 \([0-9a-f]*\)$/\1/p' "$u/userdata.txt")
		tail_seek=$(sed -n 's/^tail: .*(seek=\([0-9]*\))$/\1/p' "$u/userdata.txt")
		[ -n "$head_blocks" ] && [ -n "$head_sha" ] && [ -n "$tail_seek" ] || { echo "mkinstaller.sh: $u/userdata.txt reads oddly" >&2; exit 1; }
		mv "$u/userdata-head.img.gz" "$WORK/uhead_${dev}_$blocks.img.gz"
		mv "$u/userdata-tail.img" "$WORK/utail_${dev}_$blocks.img"
		MEMBERS+=("uhead_${dev}_$blocks.img.gz=$WORK/uhead_${dev}_$blocks.img.gz" "utail_${dev}_$blocks.img=$WORK/utail_${dev}_$blocks.img")
		h="UHEAD_${key}_$blocks" t="UTAIL_${key}_$blocks"
		PROP+="${h}_OFF=@${h}_OFF@
${h}_SIZE=@${h}_SIZE@
${h}_BLOCKS=$((head_blocks + 1))
${h}_DATA_SHA256=$head_sha
${t}_OFF=@${t}_OFF@
${t}_SIZE=@${t}_SIZE@
${t}_SHA256=@${t}_SHA256@
${t}_SEEK=$tail_seek
"
	done
done
for dev in starlte star2lte crownlte; do
	[ -z "$(get UBLOCKS $dev)" ] || [ -n "$(get KERNEL $dev)" ] || { echo "mkinstaller.sh: -u $dev=...: no -k $dev" >&2; exit 2; }
done
BUILD="Scion $(git -C "$KREPO" describe --always --dirty 2>/dev/null || echo '?'), $(date -u +%Y-%m-%d), for$DEVS, system on $PART$(if [ "$FORMAT" = 1 ]; then echo ", formats USERDATA"; fi)"
PROP+="DEVICES=\"${DEVS# }\"
SCION_BUILD=\"$BUILD\"
"
printf '%s' "$PROP" > "$WORK/installer.prop.in"
mkdir -p "$(dirname "$OUT")"
python3 "$REPO/tools/storedzip.py" "$OUT" "$WORK/installer.prop.in" \
	META-INF/com/google/android/update-binary="$HERE/update-binary" \
	META-INF/com/google/android/updater-script="$HERE/updater-script" \
	"${MEMBERS[@]}" system.apfs="$SYSTEM"
echo "mkinstaller.sh: $OUT: $(( $(wc -c < "$OUT") / 1048576 )) MB, for$DEVS, the system image to $PART$(if [ "$FORMAT" = 1 ]; then echo "; formats USERDATA"; fi)"
echo "mkinstaller.sh: yours only (iOS's files and your iPhone's identity are in it): hand it on privately"
