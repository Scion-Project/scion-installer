#!/usr/bin/env python3
# SPDX-License-Identifier: MIT-0
"""Index a directory of .deb files as a static apt repository that Sileo (and apt) read: Packages, Packages.gz,
Packages.xz, Packages.bz2 and Release, beside the debs. No apt tools needed (pure Python, so it runs on a Mac too).

usage: repo/mkrepo.py DIR [--origin NAME] [--label NAME] [--description TEXT] [--arch ARCH] [--sign KEYID]

DIR holds the .deb files (anywhere below it). The repository is flat ("Suites: ./"), as Havoc and Chariz are:
    DIR/Release  DIR/Packages(.gz|.xz|.bz2)  DIR/debs/NAME.deb
Filename: lines are relative to DIR, which is the repository's URL.

The index is made the same every time from the same debs (no clock but SOURCE_DATE_EPOCH, if you set it), so a
rebuilt repository that did not change does not show as changed in git.

--sign KEYID makes Release.gpg and InRelease with `gpg`, with a key you have made and keep; this script never makes
or holds one. Without it the repository is unsigned: apt needs `Trusted: yes` for it (the .sources line in
repo/README.md), which Sileo's own "add source" does for an unsigned repository.
"""
import argparse
import bz2
import gzip
import hashlib
import io
import lzma
import os
import subprocess
import sys
import tarfile
import time


def control_of(path):
    """The control file of a .deb: an ar archive whose control.tar.* holds ./control."""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:8] != b'!<arch>\n':
        sys.exit('mkrepo.py: %s: not an ar archive' % path)
    pos = 8
    while pos + 60 <= len(data):
        name = data[pos:pos + 16].decode().strip().rstrip('/')
        size = int(data[pos + 48:pos + 58].decode().strip())
        body = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)
        if name.startswith('control.tar'):
            if name.endswith('.zst'):
                sys.exit('mkrepo.py: %s: control.tar.zst: build with -Zxz or -Zgzip (Python has no zstd)' % path)
            with tarfile.open(fileobj=io.BytesIO(body), mode='r:*') as tar:
                for member in tar.getmembers():
                    if os.path.normpath(member.name) == 'control':
                        return tar.extractfile(member).read().decode('utf-8')
    sys.exit('mkrepo.py: %s: no control file' % path)


def digests(data):
    return hashlib.md5(data).hexdigest(), hashlib.sha1(data).hexdigest(), hashlib.sha256(data).hexdigest()


def fields(control):
    """Ordered (key, value) pairs of a control stanza; continuation lines stay with their field."""
    out = []
    for line in control.rstrip('\n').split('\n'):
        if line[:1] in ' \t' and out:
            out[-1][1] += '\n' + line
        elif ':' in line:
            key, value = line.split(':', 1)
            out.append([key, value.strip()])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--origin', default='Scion')
    ap.add_argument('--label', default='Scion')
    ap.add_argument('--description', default='Packages for Scion: web apps and open-source tools')
    ap.add_argument('--arch', default='iphoneos-arm64')
    ap.add_argument('--sign')
    args = ap.parse_args()
    root = os.path.abspath(args.dir)
    debs = sorted(os.path.join(d, n) for d, _, names in os.walk(root) for n in names if n.endswith('.deb'))
    if not debs:
        sys.exit('mkrepo.py: no .deb files under %s' % root)
    stanzas = []
    for path in debs:
        data = open(path, 'rb').read()
        md5, sha1, sha256 = digests(data)
        kv = fields(control_of(path))
        have = {k for k, _ in kv}
        for need in ('Package', 'Version', 'Architecture'):
            if need not in have:
                sys.exit('mkrepo.py: %s: no %s in its control file' % (path, need))
        arch = dict(kv)['Architecture']
        if arch != args.arch:
            sys.exit('mkrepo.py: %s: Architecture %s, not %s (a rootless package of this repository)' % (path, arch, args.arch))
        kv = [p for p in kv if p[0] not in ('Filename', 'Size', 'MD5sum', 'SHA1', 'SHA256')]
        kv += [['Filename', os.path.relpath(path, root)], ['Size', str(len(data))],
               ['MD5sum', md5], ['SHA1', sha1], ['SHA256', sha256]]
        stanzas.append((dict(kv)['Package'], '\n'.join('%s: %s' % (k, v) for k, v in kv)))
    names = [n for n, _ in stanzas]
    if len(set(names)) != len(names):
        sys.exit('mkrepo.py: a package twice: %s' % sorted(n for n in set(names) if names.count(n) > 1))
    packages = ('\n\n'.join(s for _, s in sorted(stanzas)) + '\n').encode('utf-8')

    files = {
        'Packages': packages,
        'Packages.gz': gzip.compress(packages, 9, mtime=0),
        'Packages.xz': lzma.compress(packages, preset=9),
        'Packages.bz2': bz2.compress(packages, 9),
    }
    for name, data in files.items():
        with open(os.path.join(root, name), 'wb') as f:
            f.write(data)
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', time.time()))
    date = time.strftime('%a, %d %b %Y %H:%M:%S UTC', time.gmtime(epoch))
    release = ['Origin: %s' % args.origin, 'Label: %s' % args.label, 'Suite: stable', 'Version: 1.0',
               'Codename: ios', 'Architectures: %s' % args.arch, 'Components: main',
               'Description: %s' % args.description, 'Date: %s' % date]
    for title, index in (('MD5Sum', 0), ('SHA1', 1), ('SHA256', 2)):
        release.append('%s:' % title)
        for name, data in sorted(files.items()):
            release.append(' %s %16d %s' % (digests(data)[index], len(data), name))
    with open(os.path.join(root, 'Release'), 'w') as f:
        f.write('\n'.join(release) + '\n')
    if args.sign:
        subprocess.run(['gpg', '--batch', '--yes', '-u', args.sign, '-abs', '-o', os.path.join(root, 'Release.gpg'),
                        os.path.join(root, 'Release')], check=True)
        subprocess.run(['gpg', '--batch', '--yes', '-u', args.sign, '--clearsign', '-o', os.path.join(root, 'InRelease'),
                        os.path.join(root, 'Release')], check=True)
    print('mkrepo.py: %d packages in %s%s' % (len(stanzas), root, ', signed' if args.sign else ', unsigned'))


if __name__ == '__main__':
    main()
