#!/bin/bash
# The Sileo repository, end to end, on Linux with nothing to install but dpkg and apt (CI runs it):
#   repo/test.sh KERNEL_CHECKOUT        (a Scion-Project/scion-kernel with the web clips: userland/webclips, tools/mk-webclips.py)
# It builds the packages twice and wants the same bytes, indexes them, has apt itself read the index and plan the
# install of the whole set (with its dependencies), fetch one package with its checksum checked, and runs the postinst
# and postrm of a package against a pretend phone, to see that the clip lands in WebClips and goes again.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=${1:?usage: repo/test.sh KERNEL_CHECKOUT}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL  $*" >&2; exit 1; }
ok() { echo "ok    $*"; }
export SOURCE_DATE_EPOCH=1794009600

python3 "$HERE/mkdebs.py" --kernel "$KERNEL" --out "$T/a" > /dev/null
python3 "$HERE/mkdebs.py" --kernel "$KERNEL" --out "$T/b" > /dev/null
[ "$(cd "$T/a" && sha256sum debs/* | sha256sum)" = "$(cd "$T/b" && sha256sum debs/* | sha256sum)" ] || fail "two builds differ"
n=$(ls "$T/a/debs" | wc -l)
clips=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["clips"]))' "$KERNEL/userland/webclips/manifest.json")
[ "$n" -eq $((clips + 1)) ] || fail "$n packages for $clips clips (and the set)"
ok "$n packages, the same bytes twice"

python3 "$HERE/mkrepo.py" "$T/a" > /dev/null
python3 "$HERE/mkrepo.py" "$T/b" > /dev/null
cmp "$T/a/Packages" "$T/b/Packages" && cmp "$T/a/Release" "$T/b/Release" || fail "two indexes differ"
[ "$(grep -c '^Package: ' "$T/a/Packages")" -eq "$n" ] || fail "Packages does not list every package"
for f in Packages Packages.gz Packages.xz Packages.bz2; do
	grep -q " $f\$" "$T/a/Release" || fail "Release does not list $f"
done
ok "Packages and Release written, the same twice"

# apt reads it
A=$T/apt
mkdir -p "$A/var/lib/apt/lists/partial" "$A/var/cache/apt/archives/partial" "$A/var/lib/dpkg" "$A/etc/apt/sources.list.d" "$A/etc/apt/preferences.d"
: > "$A/var/lib/dpkg/status"
echo "deb [trusted=yes] file://$T/a ./" > "$A/etc/apt/sources.list"
cat > "$A/apt.conf" <<CONF
Dir "$A";
Dir::State::status "$A/var/lib/dpkg/status";
APT::Architecture "iphoneos-arm64";
APT::Architectures "iphoneos-arm64";
Debug::NoLocking "1";
CONF
export APT_CONFIG=$A/apt.conf
apt-get update > "$T/update.log" 2>&1 || { cat "$T/update.log"; fail "apt-get update"; }
grep -q 'Hash Sum mismatch\|Bad header\|Malformed' "$T/update.log" && fail "apt found the index wrong"
planned=$(apt-get -s install com.scion.webclips 2>&1 | grep -c '^Inst ' || true)
[ "$planned" -eq "$n" ] || fail "apt plans $planned installs, not $n"
(cd "$T" && apt-get download com.scion.webclip-osm > /dev/null 2>&1) || fail "apt could not fetch a package"
ok "apt reads the index, plans all $n installs, fetches a package with its hashes checked"

# the maintainer scripts, against a pretend phone: /var/jb and /var/mobile are made under $T/phone
P=$T/phone
mkdir -p "$P/var/mobile/Library/WebClips" "$P/bin"
deb=$(ls "$T/a/debs"/com.scion.webclip-osm_*.deb)
dpkg-deb -x "$deb" "$P"
dpkg-deb -e "$deb" "$T/ctl"
uuid=$(ls "$P/var/jb/usr/share/scion/webclips")
rewrite() { sed -e "s#/var/jb/bin/sh#/bin/sh#" -e "s#/var/jb/#$P/var/jb/#g" -e "s#/var/mobile/#$P/var/mobile/#g" "$1" > "$T/s.sh"; }
rewrite "$T/ctl/postinst"; sh "$T/s.sh" configure > "$T/post.log" 2>&1 || { cat "$T/post.log"; fail "postinst"; }
[ -f "$P/var/mobile/Library/WebClips/$uuid/Info.plist" ] && [ -f "$P/var/mobile/Library/WebClips/$uuid/icon.png" ] || fail "postinst put no clip in WebClips"
rewrite "$T/ctl/postrm"; sh "$T/s.sh" remove
[ ! -e "$P/var/mobile/Library/WebClips/$uuid" ] || fail "postrm left the clip"
sh "$T/s.sh" upgrade
ok "postinst puts the clip in WebClips, postrm takes it away"
echo "repo/test.sh: all passed"
