#!/bin/bash
# SPDX-License-Identifier: MIT-0
# tools/prebuilt-pack.sh WORK OUT [RUN-URL]: the prebuilt workflow's archives, from a work directory that
# build-installer.sh --open --from-source --device all, tools/mk-mesa.sh and tools/mk-panvk.sh ios have built in.
#
# Each archive holds the built files, LICENSES/ (the licence texts and notices that go with them) and SOURCE.md (the
# exact sources: repository, commit, upstream release and SHA-256, patches). OUT gets the archives, SHA256SUMS and
# BUILDINFO.md (the release's notes). It refuses what must not be published (see the checks below).
set -euo pipefail
W=$(cd "${1:?WORK}" && pwd)
OUT=${2:?OUT}
RUN=${3:-}
K=$W/scion-kernel
die() { echo "prebuilt-pack: $*" >&2; exit 1; }
[ -d "$K/.git" ] || die "$K: no kernel repository"
REV=$(git -C "$K" rev-parse HEAD)
rm -rf "$OUT" && mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
prof() { (cd "$K" && OS_PROFILE_QUIET=1 python3 tools/os-profile.py get "$1"); }

# --- what must never be in a published file --------------------------------------------------------------------------
# No IPSW was given to this build: the identity the loader was built with is the placeholder (the loader is not
# published anyway), and the system image is the stand-in. Should anything of an IPSW be in the work directory, stop.
[ ! -e "$K/sysimage/rootfs" ] && [ ! -e "$K/sysimage/DeviceTree.d22ap.im4p" ] || die "$K/sysimage has an unpacked IPSW: not a build to publish from"
grep -q 'placeholder\|PLACEHOLDER' "$K/xnuloader/identity.h" || die "xnuloader/identity.h is not the placeholder's"
# Apple's model and board names, which an identity from an IPSW would put in a binary (as the kernel repository's
# docs/legal-review.md checked prebuilt/loader.efi): none of them in anything published
apple_names='iPhone10,3|iPhone10,6|D22AP|D221AP'

notices_kernel() { # DIR: the kernel's licences and notices
	local d=$1/LICENSES
	mkdir -p "$d"
	for f in LICENSE LICENSE.APSL NOTICE THIRD_PARTY_LICENSES.md LICENSING.md LICENSES.md COMPLIANCE.md; do
		[ -f "$K/$f" ] && cp "$K/$f" "$d/"
	done
	[ -d "$K/LICENSES" ] && cp -R "$K/LICENSES" "$d/scion-kernel-LICENSES"
}
source_kernel() { # FILE DEVICE
	cat > "$1" <<MD
# Source of kernel-$2

Built by the prebuilt workflow of Scion-Project/scion-installer${RUN:+ ($RUN)} with \`make ${2}_defconfig && make kernel\`
(build-installer.sh --open --from-source; no IPSW, nothing of Apple's but its open source and the public SDK's headers).

- Scion's kernel repository: https://github.com/Scion-Project/scion-kernel/tree/$REV (drivers/, configs, xnu/apply.sh)
- XNU: Apple's open source, tag $(prof xnu_tag) (https://github.com/apple-oss-distributions/xnu/tree/$(prof xnu_commit)),
  APSL 2.0, with Scion's changes: the fork $(prof xnu_fork) at $(prof fork_commit) (branch $(prof fork_branch))
- The device repository: $(git -C "$K/devices/$2" remote get-url origin 2>/dev/null || echo "devices/$2") at $(git -C "$K/devices/$2" rev-parse HEAD 2>/dev/null || echo '?')
MD
	if [ "$2" = starlte ]; then
		echo "- The Wi-Fi driver: Linux's brcmfmac (ISC), the files and release tools/mk-brcmfmac.sh pins, with wifi/lx/brcmfmac/patches/; their notices in LICENSES/brcmfmac-NOTICE.txt" >> "$1"
	fi
	echo "- Licences: LICENSES/ (APSL 2.0 for the XNU-derived kernel and drivers/, MIT and MIT-0 for Scion's own files, as LICENSING.md says)" >> "$1"
}

# --- the kernels -------------------------------------------------------------------------------------------------------
published=
for d in starlte star2lte crownlte; do
	f=$W/kernels/kernel-$d
	[ -f "$f" ] || die "$f: not built"
	if [ "$d" = star2lte ] && ls "$K"/xnu-deps/build/star2-camera/*.h >/dev/null 2>&1; then
		# the S9+'s camera driver was in: its kernel holds the setfiles made from Samsung's GPL headers (firmware in substance)
		echo "prebuilt-pack: kernel-star2lte NOT packed: it was built with the camera driver, whose sensor setfiles (tools/mk-star2-setfiles.sh) are fetched, never republished" >&2
		continue
	fi
	! grep -aqE "$apple_names" "$f" || die "kernel-$d names an iPhone model or board: not published"
	a=$T/kernel-$d && mkdir -p "$a"
	cp "$f" "$a/kernel-$d"
	notices_kernel "$a"
	if [ "$d" = starlte ]; then
		B=$K/xnu-deps/build/brcmfmac/src
		[ -d "$B" ] || die "$B: brcmfmac's sources are not there"
		{
			echo "Linux's brcmfmac, built into kernel-starlte (tools/mk-brcmfmac.sh checks that every file says SPDX-License-Identifier: ISC)."
			echo
			echo "Copyright notices of its files:"
			grep -rhoE 'Copyright \(c\).*' "$B" | sed 's/[[:space:]]*\*\/.*$//' | sort -u
			echo
			echo "The ISC licence, as the files carry it:"
			echo
			cat <<'ISC'
Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
ISC
		} > "$a/LICENSES/brcmfmac-NOTICE.txt"
	fi
	source_kernel "$a/SOURCE.md" "$d"
	(cd "$T" && tar -cJf "$OUT/kernel-$d.tar.xz" "kernel-$d")
	published="$published kernel-$d"
done

# --- Mesa and PanVK ----------------------------------------------------------------------------------------------------
mesa_pack() { # NAME OUT-DIR SCRIPT PATCHES...
	local name=$1 src=$2 script=$3; shift 3
	local a=$T/$name tree
	[ -f "$src/built-from" ] || die "$src: not built ($script)"
	mkdir -p "$a/LICENSES" "$a/patches"
	find "$src" -maxdepth 1 -type f -exec cp {} "$a/" \;
	! grep -aqE "$apple_names" "$a"/* || die "$name names an iPhone model or board: not published"
	tree=$(ls -d "$(dirname "$src")"/mesa-*/ 2>/dev/null | head -1)
	[ -n "$tree" ] || tree=$(ls -d "$(dirname "$(dirname "$src")")"/mesa-*/ | head -1)
	cp "$tree/docs/license.rst" "$a/LICENSES/mesa-license.rst"
	[ -d "$tree/licenses" ] && cp -R "$tree/licenses" "$a/LICENSES/mesa-licenses"
	[ -d "$tree/LICENSES" ] && cp -R "$tree/LICENSES" "$a/LICENSES/mesa-LICENSES"
	cp "$K/LICENSE" "$a/LICENSES/scion-kernel-LICENSE"
	[ -f "$K/THIRD_PARTY_LICENSES.md" ] && cp "$K/THIRD_PARTY_LICENSES.md" "$a/LICENSES/"
	local p
	for p in "$@"; do cp -R "$p" "$a/patches/"; done
	local ver sha
	ver=$(sed -n 's/^VERSION=//p' "$K/$script" | head -1)
	sha=$(sed -n 's/^SHA256=//p' "$K/$script" | head -1)
	cat > "$a/SOURCE.md" <<MD
# Source of $name

Built by the prebuilt workflow of Scion-Project/scion-installer${RUN:+ ($RUN)} with the kernel repository's $script
(https://github.com/Scion-Project/scion-kernel/blob/$REV/$script), with the cross compiler of the kernel build
(xnu-deps/host/bin/xnu-clang) against theos's public iPhoneOS16.5.sdk (not included).

- Mesa $ver, MIT (LICENSES/mesa-license.rst lists the licences of its parts): https://archive.mesa3d.org/mesa-$ver.tar.xz,
  SHA-256 $sha
- with the patches in patches/, as the kernel repository has them at $REV (tools/mesa/), applied in the order
  $script applies them
- gl.xml is the Khronos registry's, as Mesa carries it (Apache-2.0, see Mesa's licence list)
MD
	(cd "$T" && tar -cJf "$OUT/$name.tar.xz" "$name")
	published="$published $name"
}
mesa_pack mesa-gles-ios "$K/xnu-deps/build/mesa/out" tools/mk-mesa.sh "$K"/tools/mesa/*.patch "$K/tools/mesa/hakios-drm"
mesa_pack panvk-ios "$K/xnu-deps/build/panvk/out" tools/mk-panvk.sh "$K"/tools/mesa/*.patch "$K/tools/mesa/panvk" "$K/tools/mesa/hakios-drm"

# --- the sums and the notes --------------------------------------------------------------------------------------------
(cd "$OUT" && sha256sum ./*.tar.xz | sed 's| \./| |' > SHA256SUMS)
SUMS=$(sha256sum "$OUT/SHA256SUMS" | cut -d' ' -f1)
{
	echo "### prebuilt-${REV:0:12}"
	echo
	echo "The parts of the Scion installer that come from no IPSW, built${RUN:+ by [the prebuilt workflow]($RUN)} from"
	echo "[Scion-Project/scion-kernel@${REV:0:12}](https://github.com/Scion-Project/scion-kernel/commit/$REV), for build-installer.sh,"
	echo "which downloads them instead of compiling them. Each archive has its licences (LICENSES/) and its exact sources (SOURCE.md)."
	echo
	echo "Nothing of Apple's but XNU's open source and what is compiled against the public SDK's headers; no vendor firmware;"
	echo "no IPSW. The system image, the small root, the loader and the boot images are still made on your machine from your"
	echo "own IPSW, and the zip stays yours."
	echo
	echo '```'
	cat "$OUT/SHA256SUMS"
	echo '```'
	echo
	echo "For build-installer.sh (KERNEL_REV=$REV):"
	echo
	echo '```'
	echo "PREBUILT_TAG=prebuilt-${REV:0:12}"
	echo "PREBUILT_SUMS=$SUMS"
	echo "PREBUILT_ITEMS=\"${published# }\""
	echo '```'
} > "$OUT/BUILDINFO.md"
ls -la "$OUT"
cat "$OUT/SHA256SUMS"
