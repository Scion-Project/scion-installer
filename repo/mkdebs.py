#!/usr/bin/env python3
"""Build the Scion repository's packages from the kernel repository's web-clip manifest.

usage: repo/mkdebs.py --kernel DIR --out DIR [--version X.Y.Z]

  --kernel DIR   a checkout of Scion-Project/scion-kernel with userland/webclips/manifest.json and tools/mk-webclips.py
  --out DIR      where the .deb files go (DIR/debs/)

Packages made (all rootless, Architecture iphoneos-arm64, files under /var/jb, nothing compiled):
  com.scion.webclip-<id>   one web app: the clip's directory in /var/jb/usr/share/scion/webclips, which the package's
                           postinst copies to /var/mobile/Library/WebClips (what Safari's "Add to Home Screen" writes)
                           and its removal takes away again
  com.scion.webclips       the whole set, as dependencies, so that one tap in Sileo installs them all

The icons and Info.plist files are tools/mk-webclips.py's, the same ones the installer's --webclips puts in the image.
Needs dpkg-deb (Linux; on a Mac build in the CI job or a container). Same input, same bytes: SOURCE_DATE_EPOCH is fixed.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

EPOCH = '1794009600'        # 2026-11-07: the mtime of every file in every package, so a rebuild is byte-identical
SHARE = 'var/jb/usr/share/scion/webclips'
MAINTAINER = 'Scion Project'

POSTINST = """#!/var/jb/bin/sh
# Put the web clip where SpringBoard looks for it. Safari's own directory, owned by mobile.
[ "$1" = configure ] || exit 0
SRC=/var/jb/usr/share/scion/webclips/{uuid}.webclip
DST=/var/mobile/Library/WebClips
[ -d "$SRC" ] || exit 0
mkdir -p "$DST"
rm -rf "$DST/{uuid}.webclip"
cp -R "$SRC" "$DST/"
chown -R mobile:mobile "$DST/{uuid}.webclip" 2>/dev/null || true
chmod -R go-w "$DST/{uuid}.webclip"
echo "{title}: added to the home screen (a respring may be needed before the icon shows)"
exit 0
"""

POSTRM = """#!/var/jb/bin/sh
case "$1" in
remove | purge) rm -rf "/var/mobile/Library/WebClips/{uuid}.webclip" ;;
esac
exit 0
"""


def control(fields):
    return ''.join('%s: %s\n' % (k, v) for k, v in fields)


def build(tmp, out, name, fields, files_from=None, scripts=None):
    root = os.path.join(tmp, name)
    os.makedirs(os.path.join(root, 'DEBIAN'))
    if files_from:
        shutil.copytree(files_from, os.path.join(root, SHARE))
    size = 0
    for d, _, names in os.walk(root):
        for n in names:
            size += os.path.getsize(os.path.join(d, n))
    with open(os.path.join(root, 'DEBIAN', 'control'), 'w') as f:
        f.write(control(fields + [('Installed-Size', str(max(1, size // 1024)))]))
    for script, text in (scripts or {}).items():
        p = os.path.join(root, 'DEBIAN', script)
        with open(p, 'w') as f:
            f.write(text)
        os.chmod(p, 0o755)
    os.chmod(root, 0o755)
    os.chmod(os.path.join(root, 'DEBIAN'), 0o755)
    for d, dirs, names in os.walk(root):
        for n in dirs + names:
            os.utime(os.path.join(d, n), (int(EPOCH), int(EPOCH)))
            if n in dirs:
                os.chmod(os.path.join(d, n), 0o755)
            elif d.endswith('DEBIAN'):
                pass
            else:
                os.chmod(os.path.join(d, n), 0o644)
    deb = os.path.join(out, 'debs', '%s_%s_iphoneos-arm64.deb' % (name, dict(fields)['Version']))
    os.makedirs(os.path.dirname(deb), exist_ok=True)
    env = dict(os.environ, SOURCE_DATE_EPOCH=EPOCH)
    subprocess.run(['dpkg-deb', '--root-owner-group', '-Zxz', '-z9', '--build', root, deb], check=True, env=env,
                   stdout=subprocess.DEVNULL)
    return deb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--version', default='1.0.0')
    args = ap.parse_args()
    manifest = os.path.join(args.kernel, 'userland', 'webclips', 'manifest.json')
    tool = os.path.join(args.kernel, 'tools', 'mk-webclips.py')
    for p in (manifest, tool):
        if not os.path.isfile(p):
            sys.exit('mkdebs.py: %s: not there (--kernel: a Scion-Project/scion-kernel checkout with the web clips)' % p)
    if shutil.which('dpkg-deb') is None:
        sys.exit('mkdebs.py: dpkg-deb is not installed (Linux: dpkg; macOS: build in a container or in CI)')
    clips = json.load(open(manifest, encoding='utf-8'))['clips']
    # the same namespace as the tool's, read from it rather than copied
    namespace = None
    for line in open(tool, encoding='utf-8'):
        if line.startswith('NAMESPACE'):
            namespace = uuid.UUID(line.split("'")[1])
    if namespace is None:
        sys.exit('mkdebs.py: no NAMESPACE in %s' % tool)
    built = []
    with tempfile.TemporaryDirectory() as tmp:
        depends = []
        for c in clips:
            cid = str(uuid.uuid5(namespace, c['id'])).upper()
            clipdir = os.path.join(tmp, 'clip-' + c['id'])
            subprocess.run([sys.executable, '-I', tool, '--manifest', manifest, '--only', c['id'], '--flat', '--out', clipdir],
                           check=True, stdout=subprocess.DEVNULL)
            name = 'com.scion.webclip-' + c['id']
            depends.append(name)
            built.append(build(tmp, args.out, name, [
                ('Package', name), ('Name', '%s (web app)' % c['title']), ('Version', args.version),
                ('Architecture', 'iphoneos-arm64'), ('Maintainer', MAINTAINER), ('Section', 'Web Apps'),
                ('Description', 'Home screen icon for %s\n Opens %s in Safari. A web clip, as Safari\'s Add to Home Screen makes\n'
                                ' one: no app is installed and nothing runs in the background. The icon is Scion\'s own.'
                                % (c['title'], c['url'])),
                ('Homepage', c['url']),
            ], clipdir, {'postinst': POSTINST.format(uuid=cid, title=c['title']), 'postrm': POSTRM.format(uuid=cid)}))
        built.append(build(tmp, args.out, 'com.scion.webclips', [
            ('Package', 'com.scion.webclips'), ('Name', 'Scion web apps'), ('Version', args.version),
            ('Architecture', 'iphoneos-arm64'), ('Maintainer', MAINTAINER), ('Section', 'Web Apps'),
            ('Depends', ', '.join('%s (= %s)' % (d, args.version) for d in depends)),
            ('Description', 'All of Scion\'s web apps\n Wikipedia, Mastodon, Element, OpenStreetMap and the rest of the set,'
                            ' as home screen icons. Remove this and the ones it pulled in to take them off again.'),
        ]))
    print('mkdebs.py: %d packages in %s' % (len(built), os.path.join(args.out, 'debs')))


if __name__ == '__main__':
    main()
