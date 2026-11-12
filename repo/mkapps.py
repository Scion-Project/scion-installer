#!/usr/bin/env python3
"""Build the open-source apps of repo/apps/ from their source and package each as a rootless deb.

usage: repo/mkapps.py --work DIR --out DIR [--theos DIR] [--only ID ...] [--no-build]

  --work DIR    where sources are checked out (DIR/src/ID) and apps are built (DIR/build/ID); never inside a git repository
                of Scion's: it holds other people's code and binaries
  --out DIR     the repository directory: debs go to DIR/debs/, each app's source archive to DIR/sources/, and
                DIR/apps.json lists the apps (name, licence, source, commit, minimum iOS) for a front end to read
  --theos DIR   a Theos with toolchain/linux/iphone and sdks/iPhoneOS16.5.sdk (default: $THEOS)
  --only ID     just these recipes (the directory names under repo/apps)
  --no-build    package what DIR/build/ID already holds (an app built on a Mac by the recipe's macOS route, for one)

A recipe is a directory repo/apps/ID with:
  app.json      the package's metadata: package, name, version, section, bundle, bundle_id, min_ios, author, homepage,
                license (SPDX), license_file (in the source), source {git, commit}, host (linux or macos), summary,
                description (lines), changes (what this build does differently from upstream's own build)
  build.sh      build.sh SRC OUT: makes OUT/<bundle> from the checkout SRC (THEOS is set). A recipe whose host is
                macos is skipped on Linux unless --no-build finds its bundle already built.

Each deb (Architecture iphoneos-arm64, everything under /var/jb):
  /var/jb/Applications/<bundle>                       the app; postinst registers it with uicache, prerm unregisters it
  /var/jb/usr/share/doc/<package>/copyright           the app's licence, as upstream ships it
  /var/jb/usr/share/doc/<package>/SOURCE              where the source is (repository, commit) and what was changed
and the control file carries License, Source-Code and Upstream-Commit beside the usual fields. The source archive
(git archive of the commit, plus the recipe) goes beside the debs, so a GPL app's corresponding source is served
from the same place as its binary.

Same input, same bytes: every file's mtime is fixed and dpkg-deb runs with SOURCE_DATE_EPOCH.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

EPOCH = 1794009600          # 2026-11-07, as mkdebs.py
MAINTAINER = 'Scion Project'
HERE = os.path.dirname(os.path.abspath(__file__))

POSTINST = """#!/var/jb/bin/sh
# Show the app on the home screen: register it with LaunchServices.
[ "$1" = configure ] || exit 0
/var/jb/usr/bin/uicache -p /var/jb/Applications/{bundle} || echo "{name}: uicache failed; run uicache -p /var/jb/Applications/{bundle}"
exit 0
"""

PRERM = """#!/var/jb/bin/sh
# Take the icon away before the bundle goes.
case "$1" in
remove | purge) /var/jb/usr/bin/uicache -u /var/jb/Applications/{bundle} 2>/dev/null || true ;;
esac
exit 0
"""


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def checkout(app, src):
    """The upstream source at the pinned commit, fetched once (shallow) and verified."""
    url, commit = app['source']['git'], app['source']['commit']
    if not os.path.isdir(os.path.join(src, '.git')):
        os.makedirs(src, exist_ok=True)
        run(['git', '-C', src, 'init', '-q'])
        run(['git', '-C', src, 'remote', 'add', 'origin', url])
    have = subprocess.run(['git', '-C', src, 'cat-file', '-e', commit + '^{commit}'], capture_output=True).returncode == 0
    if not have:
        run(['git', '-C', src, 'fetch', '-q', '--depth', '1', 'origin', commit])
    run(['git', '-C', src, 'checkout', '-q', '--detach', commit])
    run(['git', '-C', src, 'submodule', 'update', '-q', '--init', '--recursive', '--depth', '1'])
    head = subprocess.run(['git', '-C', src, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
    if head != commit:
        sys.exit('mkapps.py: %s is at %s, not %s' % (src, head, commit))


def fix_tree(root):
    """Fixed modes and mtimes, so a rebuild is byte-identical. Mach-O files and scripts keep their execute bit."""
    for d, dirs, names in os.walk(root):
        for n in dirs:
            os.chmod(os.path.join(d, n), 0o755)
        for n in names:
            p = os.path.join(d, n)
            if os.path.islink(p):
                continue
            with open(p, 'rb') as f:
                magic = f.read(4)
            exe = magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe') or magic[:2] == b'#!' or d.endswith('DEBIAN')
            os.chmod(p, 0o755 if exe else 0o644)
    for d, dirs, names in os.walk(root):
        for n in dirs + names:
            os.utime(os.path.join(d, n), (EPOCH, EPOCH), follow_symlinks=False)
    os.utime(root, (EPOCH, EPOCH))


def package(rid, app, recipe, src, built, out):
    pkg, bundle = app['package'], app['bundle']
    commit = app['source']['commit']
    browse = app['source']['git'].removesuffix('.git')
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, pkg)
        appdir = os.path.join(root, 'var/jb/Applications', bundle)
        doc = os.path.join(root, 'var/jb/usr/share/doc', pkg)
        shutil.copytree(os.path.join(built, bundle), appdir, symlinks=True)
        os.makedirs(doc)
        shutil.copy(os.path.join(src, app['license_file']), os.path.join(doc, 'copyright'))
        with open(os.path.join(doc, 'SOURCE'), 'w') as f:
            f.write('%s %s, built from source for Scion.\n\n' % (app['name'], app['version']))
            f.write('Licence: %s (the file copyright beside this one)\n' % app['license'])
            f.write('Source: %s\nCommit: %s\nBrowse: %s/tree/%s\n' % (app['source']['git'], commit, browse, commit))
            f.write('Recipe: repo/apps/%s in Scion-Project/scion-installer\n' % rid)
            f.write('Source archive: sources/%s_%s.tar.gz in the repository this package came from\n\n' % (pkg, app['version']))
            f.write('Changes from the upstream build:\n')
            for c in app.get('changes', []):
                f.write('- %s\n' % c)
        size = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(root) for n in ns)
        os.makedirs(os.path.join(root, 'DEBIAN'))
        desc = app['summary'] + ''.join('\n ' + (line or '.') for line in app['description'])
        fields = [
            ('Package', pkg), ('Name', app['name']), ('Version', app['version']), ('Architecture', 'iphoneos-arm64'),
            ('Maintainer', MAINTAINER), ('Author', app['author']), ('Section', app['section']),
            ('Installed-Size', str(max(1, size // 1024))),
            ('Homepage', app['homepage']), ('License', app['license']),
            # not Source:, which in a binary package names its source package and which apt and dpkg parse
            ('Source-Code', '%s/tree/%s' % (browse, commit)), ('Upstream-Commit', commit),
            ('Description', desc),
        ]
        depends = ['firmware (>= %s)' % app['min_ios']] + ([app['depends']] if app.get('depends') else [])
        fields.insert(7, ('Depends', ', '.join(depends)))
        with open(os.path.join(root, 'DEBIAN/control'), 'w') as f:
            f.write(''.join('%s: %s\n' % kv for kv in fields))
        for name, text in (('postinst', POSTINST), ('prerm', PRERM)):
            with open(os.path.join(root, 'DEBIAN', name), 'w') as f:
                f.write(text.format(bundle=bundle, name=app['name']))
        fix_tree(root)
        deb = os.path.join(out, 'debs', '%s_%s_iphoneos-arm64.deb' % (pkg, app['version']))
        os.makedirs(os.path.dirname(deb), exist_ok=True)
        run(['dpkg-deb', '--root-owner-group', '-Zxz', '-z9', '--build', root, deb],
            env=dict(os.environ, SOURCE_DATE_EPOCH=str(EPOCH)), stdout=subprocess.DEVNULL)
    # the corresponding source: upstream at the commit, and the recipe that built it
    sources = os.path.join(out, 'sources')
    os.makedirs(sources, exist_ok=True)
    base = '%s_%s' % (pkg, app['version'])
    tar = os.path.join(sources, base + '.tar')
    run(['git', '-C', src, 'archive', '--format=tar', '--prefix=%s/upstream/' % base, '-o', tar, commit])
    run(['tar', '--append', '-f', tar, '--transform', 's,^,%s/recipe/,' % base, '--sort=name', '--owner=0', '--group=0',
         '--mtime=@%d' % EPOCH, '-C', recipe, '.'])
    run(['gzip', '-n', '-9', '-f', tar])
    return deb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--work', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--theos', default=os.environ.get('THEOS'))
    ap.add_argument('--only', nargs='*')
    ap.add_argument('--no-build', action='store_true')
    args = ap.parse_args()
    if shutil.which('dpkg-deb') is None:
        sys.exit('mkapps.py: dpkg-deb is not installed')
    work, out = os.path.abspath(args.work), os.path.abspath(args.out)
    apps_dir = os.path.join(HERE, 'apps')
    ids = args.only or sorted(d for d in os.listdir(apps_dir) if os.path.isfile(os.path.join(apps_dir, d, 'app.json')))
    index, made = [], []
    for rid in ids:
        recipe = os.path.join(apps_dir, rid)
        app = json.load(open(os.path.join(recipe, 'app.json'), encoding='utf-8'))
        src = os.path.join(work, 'src', rid)
        built = os.path.join(work, 'build', rid)
        checkout(app, src)
        if not args.no_build:
            if app.get('host', 'linux') != 'linux' and sys.platform != 'darwin':
                print('mkapps.py: %s needs macOS (host %s): build it there and package it with --no-build' % (rid, app['host']))
                continue
            if not args.theos:
                sys.exit('mkapps.py: --theos or THEOS is needed to build')
            run(['bash', os.path.join(recipe, 'build.sh'), src, built], env=dict(os.environ, THEOS=args.theos))
        if not os.path.isdir(os.path.join(built, app['bundle'])):
            sys.exit('mkapps.py: %s: no %s in %s' % (rid, app['bundle'], built))
        made.append(package(rid, app, recipe, src, built, out))
        index.append({k: app[k] for k in ('package', 'name', 'version', 'section', 'bundle_id', 'min_ios', 'author',
                                          'homepage', 'license', 'source', 'summary')})
    listing = os.path.join(out, 'apps.json')
    if os.path.isfile(listing):                         # --only: keep the other apps' entries
        done = {a['package'] for a in index}
        index += [a for a in json.load(open(listing, encoding='utf-8'))['apps'] if a['package'] not in done]
    index.sort(key=lambda a: a['package'])
    with open(listing, 'w') as f:
        json.dump({'apps': index}, f, indent=1, sort_keys=True)
        f.write('\n')
    print('mkapps.py: %d app packages in %s' % (len(made), os.path.join(out, 'debs')))


if __name__ == '__main__':
    main()
