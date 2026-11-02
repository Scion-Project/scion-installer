#!/bin/bash
# universal/selftest.sh: the universal installer made from stand-ins and run against a pretend TWRP, on this computer.
# Nothing of Apple's or Samsung's: the "system image" is 64 KB with APFS's magic, the "kernels" and boot images are a few
# bytes, the partitions are files. update-binary runs as TWRP runs it (sh, its arguments, its output pipe), with only the
# places it looks for partitions, the check that they are block devices and blockdev's (a busybox applet would win
# over a stand-in on PATH) and /proc/self/fd (macOS has /dev/fd) changed (sed, into a copy).
#
#   [SH=busybox\ sh] universal/selftest.sh [-U]      -U also formats a pretend USERDATA (needs mkfs.hfsplus, or newfs_hfs on a Mac: MKFS=)
#
# What it checks: an S9, an S9+ and a Note9 each get their own boot image and the system image, read back right; a
# Duos (FD) model is taken; a Korean model and an unknown phone are refused and nothing is written; a phone whose
# boot loader and device name disagree is refused; EFS, RECOVERY and RADIO are never touched; with -U, USERDATA gets
# exactly the volume mkdatavol.py made, and a renamed zip refuses to format it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FORMAT=0
[ "${1:-}" = -U ] && FORMAT=1
T=$(mktemp -d "${TMPDIR:-/tmp}/scion-selftest.XXXXXX")
[ -n "${KEEP:-}" ] && echo "selftest: kept in $T" || trap 'rm -rf "$T"' EXIT
fail() { echo "selftest: FAIL: $*" >&2; exit 1; }

# a pretend kernel repository: each phone's mkimage.sh writes its arguments as the "boot image"
K=$T/k
mkdir -p "$K/tools" "$K/userland"
for d in starlte star2lte crownlte; do
	mkdir -p "$K/devices/$d"
	cat > "$K/devices/$d/mkimage.sh" <<EOF
#!/bin/bash
while getopts o:k:r:s:qU opt; do case \$opt in o) OUT=\$OPTARG ;; s) SECS=\$OPTARG ;; *) ;; esac; done
shift \$((OPTIND - 1))
printf 'BOOT %s secs=%s %s\n' $d "\$SECS" "\$*" > "\$OUT"
EOF
	chmod +x "$K/devices/$d/mkimage.sh"
	echo "kernel $d" > "$T/kernel-$d"
done
[ "$FORMAT" = 0 ] || cp "$HERE/../../hackios-xnu-kernel/tools/mkdatavol.py" "$K/tools/" 2>/dev/null ||
	cp "${SCION_KERNEL:?SCION_KERNEL: the kernel repository, for tools/mkdatavol.py}/tools/mkdatavol.py" "$K/tools/"
echo root > "$K/userland/root.apfs"
head -c 32 /dev/zero > "$T/system.apfs"; printf NXSB >> "$T/system.apfs"; head -c 65500 /dev/urandom >> "$T/system.apfs"

UBLOCKS=262144                                   # a 1 GiB USERDATA, the smallest mkdatavol.py makes
ZIPNAME=scion-exynos9810-installer$(if [ "$FORMAT" = 1 ]; then echo -format-userdata; fi).zip
"$HERE/mkinstaller.sh" -K "$K" -s "$T/system.apfs" -k starlte="$T/kernel-starlte" -k star2lte="$T/kernel-star2lte" \
	-k crownlte="$T/kernel-crownlte" -a crownlte="usb_gadget=5" -o "$T/$ZIPNAME" \
	$(if [ "$FORMAT" = 1 ]; then echo "-U -u star2lte=$UBLOCKS"; fi) > "$T/make.log" 2>&1 || { cat "$T/make.log"; fail "mkinstaller.sh"; }
grep -q 'starlte: boot-args cpus=2 bootcpu=2 exynos_keys=1' "$T/make.log" || fail "the S9's boot-args are not starlte/mkinstaller.sh's"
grep -q 'crownlte: boot-args cpus=2 bootcpu=2 ufs=2 tmu=3 esslog=1 .*system_apfs=ufs_SYSTEM usb_gadget=5' "$T/make.log" ||
	fail "the Note9's boot-args: $(grep crownlte: "$T/make.log")"
unzip -tq "$T/$ZIPNAME" > /dev/null 2>&1 || python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None" "$T/$ZIPNAME" ||
	fail "the zip does not read back"

# the pretend TWRP: update-binary with its partitions in $T/dev, getprop from $T/props
sed -e "s|for d in /dev/block/by-name /dev/block/platform/\*/by-name /dev/block/bootdevice/by-name; do|for d in $T/dev; do|" \
	-e 's|\[ -b "\$2" \]|[ -f "$2" ]|' -e "s|blockdev --getsize64|$T/bin/blockdev --getsize64|" -e "s|/proc/self/fd/|/dev/fd/|g" "$HERE/update-binary" > "$T/update-binary"
grep -q "for d in $T/dev; do" "$T/update-binary" || fail "the sed of update-binary missed"
mkdir -p "$T/bin"
cat > "$T/bin/getprop" <<EOF
#!/bin/sh
grep "^\$1=" "$T/props" | cut -d= -f2-
EOF
cat > "$T/bin/blockdev" <<'EOF'
#!/bin/sh
[ "$1" = --getsize64 ] && wc -c < "$2" | tr -d ' '
EOF
chmod +x "$T/bin/getprop" "$T/bin/blockdev"
run() { # BOOTLOADER MODEL DEVICE ZIP: 0 if update-binary succeeded
	rm -rf "$T/dev" && mkdir -p "$T/dev"
	for p in EFS RECOVERY RADIO CPEFS; do printf "%s untouched" "$p" > "$T/dev/$p"; done
	head -c 1048576 /dev/zero > "$T/dev/BOOT"; head -c 262144 /dev/zero > "$T/dev/SYSTEM"
	dd if=/dev/zero of="$T/dev/USERDATA" bs=4096 count=0 seek=$UBLOCKS 2>/dev/null
	printf 'ro.boot.bootloader=%s\nro.product.model=%s\nro.product.device=%s\n' "$1" "$2" "$3" > "$T/props"
	PATH="$T/bin:$PATH" ${SH:-sh} "$T/update-binary" 3 1 "$4" 1> "$T/twrp.out" 2>&1
}
untouched() {
	for p in EFS RECOVERY RADIO CPEFS; do [ "$(cat "$T/dev/$p")" = "$p untouched" ] || fail "$p was written"; done
	cmp -s <(head -c 1048576 /dev/zero) "$T/dev/BOOT" || [ "${1:-}" = written ] || fail "BOOT was written"
}
check() { # DEVICE: BOOT and SYSTEM hold that phone's
	head -c "$(wc -c < "$T/system.apfs")" "$T/dev/SYSTEM" | cmp -s - "$T/system.apfs" || fail "$1: SYSTEM is not the system image"
	grep -q "^BOOT $1 " "$T/dev/BOOT" || fail "$1: BOOT holds $(head -c 40 "$T/dev/BOOT")"
	untouched written
	echo "selftest: $1: BOOT and SYSTEM right, EFS RECOVERY RADIO CPEFS untouched$(if [ "$FORMAT" = 1 ] && [ "$1" = star2lte ]; then echo ", USERDATA formatted"; fi)"
}
Z=$T/$ZIPNAME
if [ "$FORMAT" = 0 ]; then
	run G960FXXU9FUG1 SM-G960F starlte "$Z" || { cat "$T/twrp.out"; fail "an S9"; }; check starlte
	grep -q 'secs=0' "$T/dev/BOOT" || fail "the S9's run has a time limit"
	run G965FXXUFFUG2 SM-G965F star2lte "$Z" || { cat "$T/twrp.out"; fail "an S9+"; }; check star2lte
	grep -q 'secs=120' "$T/dev/BOOT" || fail "the S9+'s first run has no time limit"
	run N960FXXS9FVA1 SM-N960F crownlte "$Z" || { cat "$T/twrp.out"; fail "a Note9"; }; check crownlte
	run G965FXXUFFUG2 SM-G965FD star2lte "$Z" || { cat "$T/twrp.out"; fail "an S9+ Duos"; }; check star2lte
	run '' SM-N960F '' "$Z" || { cat "$T/twrp.out"; fail "a Note9 known by its model alone"; }; check crownlte
else
	run G965FXXUFFUG2 SM-G965F star2lte "$Z" || { cat "$T/twrp.out"; fail "an S9+ with USERDATA"; }; check star2lte
	# the volume as written: its header ('H+' or 'HX' at 1024) and the alternate one, 1024 bytes before the end
	sig=$(dd if="$T/dev/USERDATA" bs=1 skip=1024 count=2 2>/dev/null); [ "$sig" = HX ] || [ "$sig" = H+ ] || fail "USERDATA has no HFS Plus header ($sig)"
	sig=$(dd if="$T/dev/USERDATA" bs=1 skip=$((UBLOCKS * 4096 - 1024)) count=2 2>/dev/null); [ "$sig" = HX ] || [ "$sig" = H+ ] || fail "USERDATA has no alternate header"
	echo "selftest: star2lte: USERDATA holds the volume, both headers in place"
	run G960FXXU9FUG1 SM-G960F starlte "$Z" && fail "an S9 with a USERDATA size the zip has no volume for was formatted"
	grep -q 'Make the zip again with: -u starlte=262144' "$T/twrp.out" || { cat "$T/twrp.out"; fail "no hint of the size"; }
	untouched; echo "selftest: starlte: no volume for its USERDATA size: refused, nothing written"
	cp "$Z" "$T/renamed.zip"
	run G965FXXUFFUG2 SM-G965F star2lte "$T/renamed.zip" && fail "a renamed zip formatted USERDATA"
	untouched; echo "selftest: a renamed format-userdata zip: refused, nothing written"
fi
run G960NKSU9FUG1 SM-G960N starltekor "$Z" && fail "a Korean S9 was taken without -N"
untouched; echo "selftest: SM-G960N: refused, nothing written"
run G973FXXU9FUG1 SM-G973F beyond1lte "$Z" && fail "a Galaxy S10 was taken"
untouched; echo "selftest: SM-G973F: refused, nothing written"
run G960FXXU9FUG1 SM-G960F crownlte "$Z" && fail "a phone whose ids disagree was taken"
untouched; echo "selftest: boot loader G960F, device crownlte: refused, nothing written"
echo "selftest: all passed"
