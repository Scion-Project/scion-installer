#!/bin/bash
# build-installer.sh: a Scion installer for the Galaxy S9, S9+ and Note9, made in one command from your own IPSW.
#
#   ./build-installer.sh --ipsw /path/to/iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw
#   ./build-installer.sh --ipsw IPSW --device all
#   ./build-installer.sh --ipsw IPSW --device starlte --format-userdata 13615227
#
#   --ipsw PATH             your own iOS 16.5 (20F66) IPSW for iPhone10,3 / iPhone10,6, 6 165 698 198 bytes. It is
#                           checked (size, BuildManifest, SHA-256) before anything else. Nothing here downloads it.
#   --device NAME           starlte (Galaxy S9, the default), star2lte (S9+), crownlte (Note9), all, or a list
#                           (starlte,crownlte). starlte alone makes starlte/mkinstaller.sh's zip; anything else, or
#                           --format-userdata, makes universal/mkinstaller.sh's.
#   --format-userdata SIZE  the zip also formats USERDATA as HFS Plus for a persistent /private/var (ANDROID'S DATA IS
#                           LOST). SIZE is USERDATA's size in 4096-byte blocks (in TWRP:
#                           echo $(( $(blockdev --getsize64 /dev/block/by-name/USERDATA) / 4096 ))), for every phone
#                           built, or DEVICE=SIZE for one. Repeatable.
#   --work DIR              where the sources and the build go (./scion-build): about 10 GB, 15 at the most while it
#                           runs; 20 GB free is asked for, besides the IPSW
#   --out DIR               where the zip and its .sha256 go (./out)
#   --kernel-ref REF        the kernel repository's commit (default: the one pinned below, which the device
#                           repositories are pinned against in its devices/manifest.conf)
#   --jobs N                parallel jobs for the kernels (default: the number of CPUs)
#   --skip-hash             skip the IPSW's SHA-256 (the size and the BuildManifest are still checked)
#   --open                  no IPSW at all: the placeholder loader (no Apple data), a stand-in system image and the
#                           open small root. The zip installs, but iOS does not start: what CI runs.
#   -- ARGS...              extra boot-arguments, over the defaults (as for the mkinstaller.sh scripts)
#
# On macOS: Xcode or the command-line tools, and from Homebrew: sevenzip lld llvm bison meson ninja.
# On Linux: theos's toolchain and iPhoneOS16.5.sdk (made in the work directory if $THEOS has none), and the packages
# listed by the prerequisite check (Debian/Ubuntu names).
#
# The zip carries iOS's own files from your IPSW, and the loader your iPhone's identity: it is yours, never to be
# published. Nothing of Apple's is in this repository or in the kernel's; the project ships none and downloads none.
set -euo pipefail

# The kernel repository's commit this script was last run against end to end. Its devices/manifest.conf pins the device
# repositories (hakios-starlte, hakios-star2lte, hakios-crownlte); tools/hakios-device.py sync checks them out there.
KERNEL_REPO=https://github.com/Scion-Project/hackios-xnu-kernel.git
KERNEL_REV=832e59c5d9e0d85e5f60b4edfa10feb2ea2ac27b

# The one IPSW the build is made for (sysimage/unpack.sh and select-system.py know only this one). These are facts
# about Apple's file, published with it; the file itself is never fetched here.
IPSW_NAME=iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw
IPSW_SIZE=6165698198
IPSW_SHA256=c1091c401f67e3aa7cdfeb2cc19e6c79be3c957aae4e097a019e9ccea07d52f2

HERE=$(cd "$(dirname "$0")" && pwd)
START=$(date +%s)
IPSW='' DEVICES=starlte WORK=$PWD/scion-build OUTDIR=$PWD/out JOBS='' SKIP_HASH=0 OPEN=0 KREF=$KERNEL_REV
UBLOCKS=()
EXTRA=()

usage() { sed -n 2,31p "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "build-installer: $*" >&2; exit 1; }
step() { printf '\n== %s (%s)\n' "$1" "$(elapsed)"; }
elapsed() { local s=$(($(date +%s) - START)); printf '%dh%02dm%02ds' $((s / 3600)) $((s / 60 % 60)) $((s % 60)); }
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }

while [ $# -gt 0 ]; do
	case "$1" in
	--ipsw) IPSW=${2:?--ipsw PATH}; shift 2 ;;
	--ipsw=*) IPSW=${1#*=}; shift ;;
	--device) DEVICES=${2:?--device NAME}; shift 2 ;;
	--device=*) DEVICES=${1#*=}; shift ;;
	--format-userdata) UBLOCKS+=("${2:?--format-userdata SIZE}"); shift 2 ;;
	--format-userdata=*) UBLOCKS+=("${1#*=}"); shift ;;
	--work) WORK=${2:?--work DIR}; shift 2 ;;
	--work=*) WORK=${1#*=}; shift ;;
	--out) OUTDIR=${2:?--out DIR}; shift 2 ;;
	--out=*) OUTDIR=${1#*=}; shift ;;
	--kernel-ref) KREF=${2:?--kernel-ref REF}; shift 2 ;;
	--kernel-ref=*) KREF=${1#*=}; shift ;;
	--jobs) JOBS=${2:?--jobs N}; shift 2 ;;
	--jobs=*) JOBS=${1#*=}; shift ;;
	--skip-hash) SKIP_HASH=1; shift ;;
	--open) OPEN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	--) shift; EXTRA=("$@"); break ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

# --- what is asked for ----------------------------------------------------------------------------------------------
case "$DEVICES" in all) DEVICES=starlte,star2lte,crownlte ;; esac
DEVLIST=
for d in $(echo "$DEVICES" | tr ',' ' '); do
	case "$d" in starlte | star2lte | crownlte) ;; *) die "--device $d: starlte (S9), star2lte (S9+), crownlte (Note9) or all" ;; esac
	case " $DEVLIST " in *" $d "*) ;; *) DEVLIST="$DEVLIST $d" ;; esac
done
DEVLIST=${DEVLIST# }
[ -n "$DEVLIST" ] || die "--device: at least one phone"
# -u for universal/mkinstaller.sh: SIZE for every phone built, or DEVICE=SIZE for one
UARGS=()
for u in ${UBLOCKS[@]+"${UBLOCKS[@]}"}; do
	case "$u" in
	*=*) d=${u%%=*} n=${u#*=}
	     case " $DEVLIST " in *" $d "*) ;; *) die "--format-userdata $u: $d is not among the phones built ($DEVLIST)" ;; esac
	     targets=$d ;;
	*) n=$u targets=$DEVLIST ;;
	esac
	case "$n" in '' | *[!0-9]*) die "--format-userdata $u: USERDATA's size in 4096-byte blocks, a number (TWRP: blockdev --getsize64 /dev/block/by-name/USERDATA, divided by 4096)" ;; esac
	[ "$n" -ge 262144 ] || die "--format-userdata $u: $n blocks is under 1 GiB; that is not a phone's USERDATA (it is counted in 4096-byte blocks)"
	for d in $targets; do UARGS+=(-u "$d=$n"); done
done
if [ "$DEVLIST" = starlte ] && [ ${#UARGS[@]} = 0 ]; then KIND=starlte; else KIND=universal; fi
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
case "$JOBS" in '' | *[!0-9]*) die "--jobs $JOBS: a number" ;; esac
if [ "$OPEN" = 1 ]; then
	[ -z "$IPSW" ] || die "--open builds without an IPSW: leave out --ipsw"
else
	[ -n "$IPSW" ] || { usage >&2; die "--ipsw PATH: your own $IPSW_NAME (nothing here downloads it); --open builds without one"; }
	[ -f "$IPSW" ] || die "--ipsw $IPSW: no such file"
	IPSW=$(cd "$(dirname "$IPSW")" && pwd)/$(basename "$IPSW")
fi
WORK=$(abs "$WORK") OUTDIR=$(abs "$OUTDIR")
KREPO=$WORK/hackios-xnu-kernel
# What the S9 is given beyond the kernel's defaults, so that the installer's S9 is the daily's, for it alone (the S9+ and
# the Note9 keep their first run). Over the defaults: Bluetooth, the sensors and the microphone in iOS, seen working on
# the phone but left out of devices/starlte's defaults for want of room on the line; rtc_pmic= makes the room, as the
# daily does (all of it, with the loader's words, in the 607 characters the kernel holds, bt=7 last).
# In the small root (GL=1 ... below): BT=1, Bluetooth's jobs and libraries; DEVICE=starlte, the firmware the S9's
# repository carries in fw/ (ABOX's for the speakers, Wi-Fi's, Bluetooth's patch, the sensor hub's). Both do nothing on
# the other two: their kernels start none of these drivers (bluetoothd finds no address and exits; launchd paces it).
S9_ARGS=
S9_USERLAND=()
case " $DEVLIST " in *" starlte "*)
	S9_ARGS="rtc_pmic= shub=6 abox_mic=1 bt=7"
	S9_USERLAND=(BT=1 DEVICE=starlte) ;;
esac

# --- prerequisites: every problem at once, each with what to do --------------------------------------------------------
case "$(uname -s)" in Darwin) HOST=macos ;; Linux) HOST=linux ;; *) die "this runs on macOS or Linux (on Windows: in WSL, in its own filesystem)" ;; esac
# Homebrew's keg-only LLVM and its lld are not on PATH by themselves
for p in /opt/homebrew/opt/lld/bin /opt/homebrew/opt/llvm/bin /usr/local/opt/lld/bin /usr/local/opt/llvm/bin /opt/homebrew/bin /usr/local/bin; do
	[ "$HOST" = macos ] && [ -d "$p" ] && case ":$PATH:" in *":$p:"*) ;; *) PATH=$PATH:$p ;; esac
done
# Debian's lld puts lld-link beside versioned names only sometimes
if [ "$HOST" = linux ] && ! command -v lld-link >/dev/null; then
	for p in /usr/lib/llvm-*/bin; do [ -x "$p/lld-link" ] && PATH=$PATH:$p && break; done
fi
export PATH
PROBLEMS=()
have() { command -v "$1" >/dev/null 2>&1; }
missing() { PROBLEMS+=("$1|$2"); }
if [ "$HOST" = macos ]; then
	B="brew install"
	xcode-select -p >/dev/null 2>&1 || missing "Xcode command-line tools" "xcode-select --install"
else
	B="sudo apt-get install"
fi
for t in git curl tar xz make perl flex bison m4; do have $t || missing "$t" "$B $t"; done
have cc || have clang || missing "a C compiler" "$B clang"
have clang || missing "clang (the loader is built with it)" "$B clang"
if have python3 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then :; else missing "python3 3.8 or newer" "$B python3"; fi
SEVENZ=
for z in 7zz 7z; do
	have $z || continue
	v=$($z i 2>/dev/null | head -3 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
	[ -n "$v" ] || v=$($z 2>&1 | head -3 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
	if [ -n "$v" ] && [ "${v%%.*}" -ge 23 ]; then SEVENZ=$z; break; fi
done
if [ "$OPEN" = 0 ] && [ -z "$SEVENZ" ]; then
	if [ "$HOST" = macos ]; then missing "7-Zip 23 or newer (it reads APFS; p7zip's 16 does not)" "brew install sevenzip"
	else missing "7-Zip 23 or newer (it reads APFS; p7zip's 16 does not)" "sudo apt-get install 7zip (Ubuntu 24.04+), or 7zz from https://7-zip.org on PATH"; fi
fi
have lld-link || missing "lld-link (the loader, an EFI application)" "$([ "$HOST" = macos ] && echo "brew install lld" || echo "sudo apt-get install lld")"
if [ "$OPEN" = 0 ]; then   # Mesa, for the S9's GPU (GL=1)
	have meson || missing "meson (Mesa, the S9's OpenGL ES)" "$B meson"
	have ninja || missing "ninja (Mesa)" "$B $([ "$HOST" = macos ] && echo ninja || echo ninja-build)"
	have llvm-ar || missing "llvm-ar (Mesa)" "$B llvm"
	have pkg-config || [ "$HOST" = macos ] || missing "pkg-config (Mesa)" "$B pkg-config"
	python3 -c 'import venv, ensurepip' 2>/dev/null || missing "python3's venv (Mesa's Mako goes into one)" "$B python3-venv"
	# Mesa's parsers want bison 3; macOS's own is 2.3 (and the kernel is built with that one: Homebrew's goes on PATH for
	# the userland step alone)
	BISON3=
	for b in "$(command -v bison 2>/dev/null)" /opt/homebrew/opt/bison/bin/bison /usr/local/opt/bison/bin/bison; do
		[ -n "$b" ] && [ -x "$b" ] || continue
		v=$("$b" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1 || true)
		if [ -n "$v" ] && [ "${v%%.*}" -ge 3 ]; then BISON3=$(dirname "$b"); break; fi
	done
	[ -n "$BISON3" ] || missing "bison 3 or newer (Mesa; macOS's /usr/bin/bison is 2.3)" "$B bison"
fi
if [ "$HOST" = linux ]; then
	for t in autoconf automake; do have $t || missing "$t" "$B $t"; done
	have libtoolize || missing "libtool" "$B libtool-bin"
	[ -e /usr/include/uuid/uuid.h ] || missing "libuuid's headers" "$B uuid-dev"
fi
if [ ${#UARGS[@]} -gt 0 ]; then
	if [ "$HOST" = macos ]; then have newfs_hfs || missing "newfs_hfs" "it is part of macOS: /sbin on PATH"
	else have mkfs.hfsplus || missing "mkfs.hfsplus (--format-userdata)" "sudo apt-get install hfsprogs"; fi
fi
# disk: the sources and the build (kernel trees, Mesa, the unpacked IPSW, the images) and the zip
need_gb=$([ "$OPEN" = 1 ] && echo 8 || echo 20)
mkdir -p "$WORK" "$OUTDIR"
free_gb=$(df -Pk "$WORK" | awk 'NR == 2 { print int($4 / 1048576) }')
used_gb=$(du -sk "$WORK" 2>/dev/null | awk '{ print int($1 / 1048576) }')
[ $((free_gb + used_gb)) -ge "$need_gb" ] || missing "disk: $free_gb GB free at $WORK, about $need_gb GB wanted" "free some space, or --work somewhere bigger"
if [ ${#PROBLEMS[@]} -gt 0 ]; then
	echo "build-installer: this machine is missing what the build needs:" >&2
	for p in "${PROBLEMS[@]}"; do printf '  - %s\n      -> %s\n' "${p%%|*}" "${p#*|}" >&2; done
	exit 1
fi
echo "build-installer: $HOST, $JOBS jobs, ${SEVENZ:-no 7-Zip (--open)}, $free_gb GB free at $WORK"
echo "build-installer: for $DEVLIST -> $KIND zip$([ ${#UARGS[@]} = 0 ] || echo ", formats USERDATA (${UARGS[*]})")"

# --- the IPSW: the one build this is made for ---------------------------------------------------------------------------
if [ "$OPEN" = 0 ]; then
	step "Checking your IPSW"
	python3 - "$IPSW" "$IPSW_SIZE" <<'EOF' || exit 1
import os, plistlib, sys, zipfile
path, size = sys.argv[1], int(sys.argv[2])
def bad(msg):
    print("build-installer: %s: %s" % (path, msg), file=sys.stderr)
    print("build-installer: the build needs iOS 16.5 (20F66) for iPhone10,3 / iPhone10,6, the file "
          "iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw that you get yourself", file=sys.stderr)
    sys.exit(1)
got = os.path.getsize(path)
if got != size:
    bad("%d bytes, not %d%s" % (got, size, " (still downloading, or cut short?)" if got < size else ""))
try:
    z = zipfile.ZipFile(path)
except zipfile.BadZipFile as e:
    bad("not an IPSW (not a zip: %s)" % e)
names = set(z.namelist())
if "BuildManifest.plist" not in names:
    bad("no BuildManifest.plist: not an IPSW")
m = plistlib.loads(z.read("BuildManifest.plist"))
build, version, types = m.get("ProductBuildVersion"), m.get("ProductVersion"), m.get("SupportedProductTypes", [])
if build != "20F66" or version != "16.5":
    bad("iOS %s (%s), not 16.5 (20F66)" % (version, build))
if "iPhone10,3" not in types or "iPhone10,6" not in types:
    bad("for %s, not iPhone10,3 / iPhone10,6" % ", ".join(types))
want = ["096-04088-077.dmg", "096-04666-078.dmg", "096-03536-083.dmg", "Firmware/all_flash/DeviceTree.d22ap.im4p"]
lost = [n for n in want if n not in names]
if lost:
    bad("lacks %s" % ", ".join(lost))
print("build-installer: %s: iOS %s (%s) for %s, %d bytes" % (os.path.basename(path), version, build, ", ".join(types), got))
EOF
	stamp=$WORK/.ipsw-checked
	id="$IPSW $(wc -c < "$IPSW" | tr -d ' ') $(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$IPSW")"
	if [ "$SKIP_HASH" = 1 ]; then
		echo "build-installer: --skip-hash: its SHA-256 is not checked"
	elif [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$id" ]; then
		echo "build-installer: SHA-256 checked before (same file, same size and time)"
	else
		echo "build-installer: SHA-256 of 6.2 GB (a minute or so)"
		sum=$(python3 -c '
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(1 << 22), b""):
        h.update(b)
print(h.hexdigest())' "$IPSW")
		[ "$sum" = "$IPSW_SHA256" ] || die "$IPSW: SHA-256 $sum, not $IPSW_SHA256: a damaged or altered copy; get it again"
		echo "$id" > "$stamp"
		echo "build-installer: SHA-256 $sum: the 20F66 IPSW"
	fi
fi

# --- the sources, at their pinned revisions ------------------------------------------------------------------------------
step "Sources: the kernel repository at ${KREF:0:12}, the device repositories its manifest pins"
if [ -d "$KREPO/.git" ]; then
	git -C "$KREPO" diff --quiet HEAD -- 2>/dev/null || die "$KREPO has local changes: commit or drop them, or use another --work"
	git -C "$KREPO" cat-file -e "$KREF^{commit}" 2>/dev/null || git -C "$KREPO" fetch -q origin || die "cannot fetch $KERNEL_REPO"
else
	git clone -q --filter=blob:none "$KERNEL_REPO" "$KREPO" || die "cannot clone $KERNEL_REPO"
fi
git -C "$KREPO" cat-file -e "$KREF^{commit}" 2>/dev/null || git -C "$KREPO" fetch -q origin "$KREF" || die "no commit $KREF in $KERNEL_REPO"
git -C "$KREPO" -c advice.detachedHead=false checkout -q "$KREF" 2>/dev/null || git -C "$KREPO" -c advice.detachedHead=false checkout -q FETCH_HEAD
(cd "$KREPO" && python3 tools/hakios-device.py sync $DEVLIST) | sed 's/^/  /'
for d in $DEVLIST; do [ -x "$KREPO/devices/$d/mkimage.sh" ] || die "devices/$d did not sync (tools/hakios-device.py sync $d)"; done
echo "  hackios-xnu-kernel $(git -C "$KREPO" rev-parse --short=12 HEAD)"
for d in $DEVLIST; do echo "  devices/$d $(git -C "$KREPO/devices/$d" rev-parse --short=12 HEAD)"; done
echo "  scion-packaging $(git -C "$HERE" rev-parse --short=12 HEAD 2>/dev/null || echo '?')$(git -C "$HERE" diff --quiet HEAD -- 2>/dev/null || echo ' (with local changes)')"
[ "$HOST" = macos ] && export PATH="$KREPO/tools/macos-bin:$PATH"   # flock, GNU timeout and stat, sha256sum

# --- Linux: theos (its cctools linker and iPhoneOS16.5.sdk), as the S9's CI lays it out --------------------------------
if [ "$HOST" = linux ]; then
	if [ -z "${THEOS:-}" ]; then
		if [ -x "$HOME/theos/toolchain/linux/iphone/bin/ld" ] && [ -d "$HOME/theos/sdks/iPhoneOS16.5.sdk" ]; then THEOS=$HOME/theos; else THEOS=$WORK/theos; fi
	fi
	export THEOS
	if [ ! -x "$THEOS/toolchain/linux/iphone/bin/ld" ]; then
		step "theos's toolchain for Linux, into $THEOS"
		TC=$WORK/tc.part && rm -rf "$TC" && mkdir -p "$TC" "$THEOS/toolchain/linux"
		curl -L --fail --retry 3 -s https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-x86_64.tar.xz | tar -xJ -C "$TC"
		LD=$(find "$TC" -path '*/bin/ld' \( -type f -o -type l \) | head -1)
		[ -n "$LD" ] || die "the toolchain's archive has no bin/ld"
		rm -rf "$THEOS/toolchain/linux/iphone" && mv "$(dirname "$(dirname "$LD")")" "$THEOS/toolchain/linux/iphone" && rm -rf "$TC"
	fi
	if [ ! -d "$THEOS/sdks/iPhoneOS16.5.sdk/usr/include" ]; then
		step "theos's iPhoneOS16.5.sdk, into $THEOS/sdks"
		S=$WORK/sdks.part && rm -rf "$S" && git init -q "$S" && git -C "$S" remote add origin https://github.com/theos/sdks.git
		git -C "$S" sparse-checkout set iPhoneOS16.5.sdk
		git -C "$S" fetch -q --depth 1 --filter=blob:none origin HEAD && git -C "$S" checkout -q FETCH_HEAD
		mkdir -p "$THEOS/sdks" && rm -rf "$THEOS/sdks/iPhoneOS16.5.sdk" && mv "$S/iPhoneOS16.5.sdk" "$THEOS/sdks/" && rm -rf "$S"
	fi
fi

cd "$KREPO"
LOGS=$WORK/logs && mkdir -p "$LOGS"
run() { # LOG CMD...: the command's output to its log; its tail on failure
	local log=$LOGS/$1; shift
	if ! "$@" > "$log" 2>&1; then
		tail -60 "$log" >&2
		die "failed: $* (the whole log: $log)"
	fi
}

# --- the IPSW unpacked, the loader's identity ------------------------------------------------------------------------
if [ "$OPEN" = 0 ]; then
	step "Unpacking your IPSW (sysimage/unpack.sh; a few minutes the first time)"
	# unpack.sh finds 7z by that name
	if [ "$SEVENZ" = 7zz ] && ! have 7z; then mkdir -p "$WORK/bin" && ln -sf "$(command -v 7zz)" "$WORK/bin/7z" && export PATH="$WORK/bin:$PATH"; fi
	# (a second run finds what it unpacked before and does not read the IPSW again for it)
	run unpack.log sysimage/unpack.sh "$IPSW"
	tail -2 "$LOGS/unpack.log" | sed 's/^/  /'
	run identity.log xnuloader/mkidentity.sh
else
	step "No IPSW (--open): the placeholder identity"
	run identity.log xnuloader/mkidentity.sh --placeholder
fi
sed -n 1p "$LOGS/identity.log" | sed 's/^/  /'

# --- the kernels, one per phone ---------------------------------------------------------------------------------------
KDIR=$WORK/kernels && mkdir -p "$KDIR"
for d in $DEVLIST; do
	step "The $d kernel (make ${d}_defconfig && make kernel; the first takes longest: XNU's tree and its dependencies)"
	run "defconfig-$d.log" make "${d}_defconfig"
	run "kernel-$d.log" make kernel JOBS="$JOBS"
	[ -f hakios-kernel ] || die "make kernel left no hakios-kernel (the log: $LOGS/kernel-$d.log)"
	cp hakios-kernel "$KDIR/kernel-$d"
	echo "  $(grep -a 'drivers built in' "$LOGS/kernel-$d.log" | tail -1 || true)"
	echo "  $KDIR/kernel-$d: $(wc -c < "$KDIR/kernel-$d" | tr -d ' ') bytes"
done
# the S9's configuration last, for devices/starlte/mkimage.sh's defaults (it reads them from .config when it is the S9's)
case " $DEVLIST " in *" starlte "*) [ "${DEVLIST##* }" = starlte ] || run defconfig-starlte.log make starlte_defconfig ;; esac

step "The loader (make loader)"
rm -f xnuloader/loader.efi
run loader.log make loader
echo "  xnuloader/loader.efi: $(wc -c < xnuloader/loader.efi | tr -d ' ') bytes"

# --- the small root and the system image ------------------------------------------------------------------------------
if [ "$OPEN" = 0 ]; then
	step "The small root and the iOS system image (userland/build.sh, with Mesa the first time: 10 to 30 minutes)"
	if ! env ${S9_USERLAND[@]+"${S9_USERLAND[@]}"} BISON3="$BISON3" bash -c 'source ./xnu-env.sh && export PATH="$BISON3:$PATH" && cd userland && GL=1 NO_AIR=1 REST=1 ALONE=1 RC=rc.launchd bash build.sh' > "$LOGS/userland.log" 2>&1; then
		tail -40 "$LOGS/userland.log" >&2
		M=xnu-deps/build/mesa
		for f in $M/meson-setup.log $M/ninja.log; do
			[ -f "$f" ] && grep -qE 'FAILED|ERROR' "$f" && { echo "-- Mesa: $KREPO/$f" >&2; grep -E -A8 -m3 'FAILED|ERROR' "$f" >&2; }
		done
		die "failed: userland/build.sh (the whole log: $LOGS/userland.log)"
	fi
	SYSTEM=$KREPO/userland/system.apfs
else
	step "The open small root (userland/build.sh, no Darwin) and a stand-in system image"
	run userland.log bash -c 'source ./xnu-env.sh && cd userland && ALONE=1 RC=rc.launchd bash build.sh'
	# an APFS container with nothing of Apple's in it: the installer checks for one, the phone would find no iOS on it
	SB=$WORK/standin-system && rm -rf "$SB" && mkdir -p "$SB/sysroot"
	echo "A stand-in system image, made by build-installer.sh --open: no iOS here." > "$SB/sysroot/README"
	run standin.log python3 tools/apfs/mkapfs.py -o "$SB/system.apfs" System="$SB/sysroot"
	SYSTEM=$SB/system.apfs
fi
ROOT=$KREPO/userland/root.apfs
for f in "$ROOT" "$SYSTEM"; do [ -f "$f" ] || die "userland/build.sh left no $f (the log: $LOGS/userland.log)"; done
echo "  root.apfs $(wc -c < "$ROOT" | tr -d ' ') bytes, system.apfs $(( $(wc -c < "$SYSTEM") / 1048576 )) MB"

# --- the installer ------------------------------------------------------------------------------------------------------
step "The installer ($KIND/mkinstaller.sh)"
MKFAIL=
if [ "$KIND" = starlte ]; then
	ZIP=$OUTDIR/scion-starlte-installer.zip
	SCION_KERNEL=$KREPO "$HERE/starlte/mkinstaller.sh" -K "$KREPO" -s "$SYSTEM" -k "$KDIR/kernel-starlte" -r "$ROOT" \
		-o "$ZIP" $S9_ARGS ${EXTRA[@]+"${EXTRA[@]}"} > "$LOGS/mkinstaller.log" 2>&1 || MKFAIL=1
else
	ZIP=$OUTDIR/scion-exynos9810-installer$([ ${#UARGS[@]} = 0 ] || echo -format-userdata).zip
	KARGS=()
	for d in $DEVLIST; do KARGS+=(-k "$d=$KDIR/kernel-$d"); done
	[ ${#UARGS[@]} = 0 ] || KARGS+=(-U "${UARGS[@]}")
	[ -z "$S9_ARGS" ] || KARGS+=(-a "starlte=$S9_ARGS")
	MKFSV=; [ "$HOST" = macos ] && MKFSV=newfs_hfs
	MKFS=${MKFS:-${MKFSV:-mkfs.hfsplus}} SCION_KERNEL=$KREPO "$HERE/universal/mkinstaller.sh" -K "$KREPO" -s "$SYSTEM" "${KARGS[@]}" -r "$ROOT" \
		-o "$ZIP" ${EXTRA[@]+"${EXTRA[@]}"} > "$LOGS/mkinstaller.log" 2>&1 || MKFAIL=1
fi
sed 's/^/  /' "$LOGS/mkinstaller.log"
[ -z "$MKFAIL" ] && [ -f "$ZIP" ] || die "$KIND/mkinstaller.sh failed (the log: $LOGS/mkinstaller.log)"
SUM=$(python3 -c '
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(1 << 22), b""):
        h.update(b)
print(h.hexdigest())' "$ZIP")
echo "$SUM  $(basename "$ZIP")" > "$ZIP.sha256"

cat <<EOF

== Done in $(elapsed)
  $ZIP
  $(( $(wc -c < "$ZIP") / 1048576 )) MB, sha256 $SUM ($(basename "$ZIP").sha256 beside it)
  for $DEVLIST; kernel repository $(git -C "$KREPO" rev-parse --short=12 HEAD)$(for d in $DEVLIST; do printf ', %s %s' "$d" "$(git -C "$KREPO/devices/$d" rev-parse --short=12 HEAD)"; done)
EOF
if [ "$OPEN" = 1 ]; then
	echo "  --open: a stand-in system image and the placeholder loader. It installs; iOS does not start."
else
	echo "  Yours only: it carries iOS's files from your IPSW and your iPhone's identity. Do not publish it."
	echo "  To install: the README's \"Install\" (TWRP: back up Boot, System and EFS first)."
fi
