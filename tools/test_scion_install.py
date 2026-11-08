#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host test of universal/scion-install.sh: the verified install, run on this computer against fake partition files.

Nothing of Apple's, Samsung's or anyone's is in it: the "boot images" and the "system image" are a few random bytes, the
partitions are files, the zip is made by tools/storedzip.py the way universal/mkinstaller.sh makes it. The script is run as a
subprocess (sh, and mksh/busybox sh when they are there), with the SCION_TEST_* hooks that point it at the fake partitions.

  python3 -I tools/test_scion_install.py            (SHELLS="sh,mksh,busybox sh" to choose the shells)

What it proves:
  - it refuses the wrong phone (another model, ids that disagree, a phone the zip has no image for, --expect-device), and writes nothing
  - it refuses a protected partition: a zip that names EFS as the system partition, a BOOT that is RECOVERY's device under another
    name, a partition table with a name missing or the same device twice, and writes nothing
  - it refuses a hash mismatch (a boot image or system image in the zip damaged, the zip's own SHA-256, a SYSTEM on the phone that is not
    the image the kernel was made with) before the first write
  - in kernel-update mode it writes BOOT and nothing else (EFS, RECOVERY, SYSTEM, USERDATA byte for byte as they were)
  - a dry run (the default) writes nothing; --apply does; the log is written and says what happened
  - a BOOT that reads back wrong is put back from its copy; RECOVERY changing during the install is a failure
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(REPO, 'universal', 'scion-install.sh')
STORED = os.path.join(HERE, 'storedzip.py')
SHELLS = os.environ.get('SHELLS', 'sh').split(',')
KIB = 1024
MIB = 1024 * KIB

# the fake phone: partition sizes inside the manifest's sanity bounds (BOOT 4..256 MiB, SYSTEM 1..16 GiB: a SYSTEM of 1 GiB is sparse)
SIZES = {'BOOT': 8 * MIB, 'RECOVERY': 4 * MIB, 'EFS': 1 * MIB, 'SYSTEM': 1024 * MIB, 'USERDATA': 1 * MIB,
         'PARAM': 1 * MIB, 'RADIO': 1 * MIB, 'PERSISTENT': 1 * MIB}
SYSTEM_IMAGE = 3 * MIB                       # the stand-in "system image"; SYSTEM's room is a sparse GiB
BOOT_IMAGE = {'starlte': 96 * KIB, 'star2lte': 64 * KIB, 'crownlte': 64 * KIB}
PHONES = {  # phone: (boot loader, model, device)
    'starlte': ('G960FXXU9FUG1', 'SM-G960F', 'starlte'),
    'star2lte': ('G965FXXUFFUG2', 'SM-G965F', 'star2lte'),
    'crownlte': ('N960FXXS9FVA1', 'SM-N960F', 'crownlte'),
}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def rand(n, seed):
    return b''.join(hashlib.sha256(('%s-%d' % (seed, i)).encode()).digest() for i in range((n + 31) // 32))[:n]


def prop_template(installer=2, system_part='SYSTEM', devices=('starlte', 'star2lte', 'crownlte'), system_literal=None):
    t = ('# fake installer.prop\nSCION_INSTALLER=%d\nSYSTEM_PART=%s\nKOREAN=0\nFORMAT_USERDATA=0\n' % (installer, system_part))
    if system_literal:
        t += 'SYSTEM_OFF=0\nSYSTEM_SIZE=%d\nSYSTEM_SHA256=%s\n' % system_literal
    else:
        t += 'SYSTEM_OFF=@SYSTEM_OFF@\nSYSTEM_SIZE=@SYSTEM_SIZE@\nSYSTEM_SHA256=@SYSTEM_SHA256@\n'
    for d in devices:
        k = d.upper()
        t += 'BOOT_%s_OFF=@BOOT_%s_OFF@\nBOOT_%s_SIZE=@BOOT_%s_SIZE@\nBOOT_%s_SHA256=@BOOT_%s_SHA256@\n' % ((k,) * 6)
        t += 'BOOT_%s_ARGS="cpus=2 system_apfs=ufs_SYSTEM"\n' % k
    t += 'DEVICES="%s"\nSCION_BUILD="test build"\n' % ' '.join(devices)
    return t


class Fixture:
    """A directory with the fake partitions (by-name), the fake props, the images and a zip of them."""

    def __init__(self, tmp):
        self.tmp = tmp
        self.bynam = os.path.join(tmp, 'by-name')
        self.share = os.path.join(tmp, 'share')
        os.makedirs(self.bynam)
        os.makedirs(self.share)
        self.images = {}
        self.system = rand(SYSTEM_IMAGE, 'system')
        self.reset_partitions()

    def reset_partitions(self):
        for n, size in SIZES.items():
            with open(os.path.join(self.bynam, n), 'wb') as f:
                content = rand(min(size, 64 * KIB), 'part-' + n)
                f.write(content)
                f.truncate(size)             # sparse
        # SYSTEM holds the right system image by default (a kernel update on a phone that has been installed)
        with open(os.path.join(self.bynam, 'SYSTEM'), 'r+b') as f:
            f.write(self.system)

    def part(self, n):
        return os.path.join(self.bynam, n)

    def digest(self, n):
        # SYSTEM is a sparse GiB: its first 16 MiB (where the image goes), its last MiB and its size stand for it
        h = hashlib.sha256()
        with open(self.part(n), 'rb') as f:
            if SIZES.get(n, 0) > 64 * MIB:
                f.seek(0, 2)
                h.update(b'%d' % f.tell())
                f.seek(0)
                h.update(f.read(16 * MIB))
                f.seek(-MIB, 2)
                h.update(f.read())
            else:
                for b in iter(lambda: f.read(8 * MIB), b''):
                    h.update(b)
        return h.hexdigest()

    def snapshot(self):
        return {n: self.digest(n) for n in SIZES}

    def make_zip(self, name='installer.zip', installer=2, system_part='SYSTEM', devices=('starlte', 'star2lte', 'crownlte'),
                 with_system=True, system_bytes=None):
        sysb = self.system if system_bytes is None else system_bytes
        members = []
        for d in devices:
            p = os.path.join(self.tmp, 'boot_%s.img' % d)
            img = b'BOOT %s ' % d.encode() + rand(BOOT_IMAGE[d] - len(b'BOOT %s ' % d.encode()), 'boot-' + d)
            with open(p, 'wb') as f:
                f.write(img)
            self.images[d] = img
            members.append('boot_%s.img=%s' % (d, p))
        if with_system:
            sp = os.path.join(self.tmp, 'system.apfs')
            with open(sp, 'wb') as f:
                f.write(sysb)
            members.append('system.apfs=' + sp)
            template = prop_template(installer, system_part, devices)
        else:
            template = prop_template(installer, system_part, devices, (len(sysb), sha(sysb)))
        tpl = os.path.join(self.tmp, 'prop.in')
        with open(tpl, 'w') as f:
            f.write(template)
        z = os.path.join(self.tmp, name)
        r = subprocess.run([sys.executable, '-I', STORED, z, tpl] + members, capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        self.zip = z
        return z

    def run(self, shell, phone='starlte', args=(), props=None, env=None, path_prefix=None):
        bl, model, dev = props if props is not None else PHONES[phone]
        pf = os.path.join(self.tmp, 'props')
        with open(pf, 'w') as f:
            f.write('ro.boot.bootloader=%s\nro.product.model=%s\nro.product.device=%s\n' % (bl, model, dev))
        gp = os.path.join(self.tmp, 'getprop')
        with open(gp, 'w') as f:
            f.write('#!/bin/sh\ngrep "^$1=" "%s" | cut -d= -f2-\n' % pf)
        os.chmod(gp, 0o755)
        e = dict(os.environ)
        e.update({'SCION_TEST_FILES': '1', 'SCION_TEST_BYNAME': self.bynam, 'SCION_TEST_GETPROP': gp,
                  'SCION_SHARE_DIR': self.share, 'SCION_LOG_DIR': self.tmp, 'TMPDIR': self.tmp})
        if path_prefix:
            e['PATH'] = path_prefix + os.pathsep + e['PATH']
        if env:
            e.update(env)
        r = subprocess.run(shell.split() + [SCRIPT] + list(args), capture_output=True, text=True, env=e)
        return r.returncode, r.stdout + r.stderr


class Base(unittest.TestCase):
    shell = 'sh'

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='scion-install-test.')
        self.f = Fixture(self.tmp)
        self.f.make_zip()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def skip_if_busybox(self):
        # busybox sh runs its own dd, not the stand-in on PATH that these tests need
        if 'busybox' in self.shell:
            self.skipTest('busybox sh runs dd as an applet: the stand-in dd on PATH is not used')

    def run_it(self, *args, **kw):
        a = ['--zip', self.f.zip] + list(args) if '--zip' not in args else list(args)
        return self.f.run(self.shell, args=a, **kw)

    def assertUntouched(self, before, out=''):
        self.assertEqual(self.f.snapshot(), before, out)

    def assertRefused(self, rc, out, before, *words):
        self.assertEqual(rc, 1, out)
        self.assertIn('REFUSED', out)
        self.assertIn('Nothing was written.', out)
        for w in words:
            self.assertIn(w, out)
        self.assertUntouched(before, out)


class Tests(Base):
    # ---- the default is a dry run -------------------------------------------------------------------------------------------
    def test_dry_run_is_the_default_and_writes_nothing(self):
        before = self.f.snapshot()
        rc, out = self.run_it()
        self.assertEqual(rc, 0, out)
        self.assertIn('DRY RUN', out)
        self.assertIn('nothing was written', out)
        self.assertUntouched(before, out)
        rc, out = self.run_it('--mode', 'full')
        self.assertEqual(rc, 0, out)
        self.assertIn('DRY RUN', out)
        self.assertUntouched(before, out)

    def test_log_is_written_and_shared(self):
        log = os.path.join(self.tmp, 'my.log')
        rc, out = self.run_it('--log', log)
        self.assertEqual(rc, 0, out)
        with open(log) as lf:
            text = lf.read()
        for w in ('this phone: boot loader', 'the partition table', 'BOOT ->', 'RECOVERY ->', 'RESULT: dry run ok', 'SHA-256'):
            self.assertIn(w, text)
        copies = os.listdir(self.f.share)
        self.assertEqual(len(copies), 1, copies)
        self.assertTrue(copies[0].startswith('scion-install-'))
        self.assertNotIn(os.path.expanduser('~'), text.replace(self.tmp, ''))
        # a refusal is logged too
        rc, out = self.run_it('--log', log, '--expect-device', 'crownlte')
        self.assertEqual(rc, 1)
        with open(log) as lf:
            self.assertIn('RESULT: refused', lf.read())

    # ---- kernel update: BOOT only ---------------------------------------------------------------------------------------------
    def test_kernel_update_writes_only_boot(self):
        before = self.f.snapshot()
        rc, out = self.run_it('--apply')
        self.assertEqual(rc, 0, out)
        after = self.f.snapshot()
        for n in SIZES:
            if n == 'BOOT':
                self.assertNotEqual(after[n], before[n], 'BOOT was not written')
            else:
                self.assertEqual(after[n], before[n], '%s was written: %s' % (n, out))
        with open(self.f.part('BOOT'), 'rb') as f:
            self.assertEqual(f.read(len(self.f.images['starlte'])), self.f.images['starlte'])
        self.assertIn('RECOVERY unchanged', out)
        with open([os.path.join(self.tmp, x) for x in os.listdir(self.tmp)
                   if x.startswith('scion-install-') and x.endswith('.log')][0]) as lf:
            self.assertIn('RESULT: ok', lf.read())
        # the backup of BOOT is kept only on failure
        self.assertEqual([x for x in os.listdir(self.tmp) if x.startswith('scion-boot-backup')], [])

    def test_kernel_update_for_each_phone_gets_its_own_image(self):
        for phone in PHONES:
            self.f.reset_partitions()
            before = self.f.snapshot()
            rc, out = self.run_it('--apply', phone=phone)
            self.assertEqual(rc, 0, '%s: %s' % (phone, out))
            with open(self.f.part('BOOT'), 'rb') as f:
                self.assertEqual(f.read(len(self.f.images[phone])), self.f.images[phone], phone)
            after = self.f.snapshot()
            self.assertEqual({n for n in SIZES if after[n] != before[n]}, {'BOOT'}, phone)

    def test_full_mode_writes_system_then_boot_and_nothing_else(self):
        # a phone that still has Android's SYSTEM
        with open(self.f.part('SYSTEM'), 'r+b') as f:
            f.write(rand(SYSTEM_IMAGE, 'android'))
        before = self.f.snapshot()
        rc, out = self.run_it('--apply', '--mode', 'full')
        self.assertEqual(rc, 0, out)
        after = self.f.snapshot()
        self.assertEqual({n for n in SIZES if after[n] != before[n]}, {'BOOT', 'SYSTEM'}, out)
        with open(self.f.part('SYSTEM'), 'rb') as f:
            self.assertEqual(f.read(SYSTEM_IMAGE), self.f.system)

    def test_kernel_update_zip_made_without_a_system_image(self):
        z = self.f.make_zip('kernel-update.zip', installer=3, with_system=False)
        before = self.f.snapshot()
        rc, out = self.f.run(self.shell, args=['--zip', z, '--apply'])
        self.assertEqual(rc, 0, out)
        after = self.f.snapshot()
        self.assertEqual({n for n in SIZES if after[n] != before[n]}, {'BOOT'}, out)
        # --mode full needs the system image in the zip
        self.f.reset_partitions()
        before = self.f.snapshot()
        rc, out = self.f.run(self.shell, args=['--zip', z, '--apply', '--mode', 'full'])
        self.assertRefused(rc, out, before, 'no system image')

    # ---- the wrong phone ---------------------------------------------------------------------------------------------------------
    def test_refuses_the_wrong_phone(self):
        before = self.f.snapshot()
        cases = [
            ('another Galaxy', ('G973FXXU9FUG1', 'SM-G973F', 'beyond1lte'), 'not a Galaxy S9'),
            ('the Snapdragon S9', ('G960USQU9FUG1', 'Galaxy S9', 'starqltesq'), 'not a Galaxy S9'),
            ('ids that disagree', ('G960FXXU9FUG1', 'SM-G960F', 'crownlte'), 'disagree'),
            ('a Korean model', ('G960NKSU9FUG1', 'SM-G960N', 'starltekor'), 'Korean'),
            ('a name and no id', ('', 'Galaxy S9', 'starlte'), 'cannot tell which phone'),
            ('a Pixel', ('', 'Pixel 10', 'frankel'), 'not a Galaxy S9'),
            ('a Pixel with no device name', ('', 'Pixel 10', ''), 'cannot tell which phone'),
            ('an S9 calling itself an S9+', ('G960FXXSFFUB3', 'Galaxy S9+', 'starlte'), 'disagree'),
        ]
        for what, props, word in cases:
            for mode in ('kernel-update', 'full'):
                rc, out = self.run_it('--apply', '--mode', mode, props=props)
                self.assertRefused(rc, out, before, word)

    def test_refuses_a_phone_the_zip_has_no_image_for(self):
        z = self.f.make_zip('s9only.zip', devices=('starlte',))
        before = self.f.snapshot()
        rc, out = self.f.run(self.shell, phone='crownlte', args=['--zip', z, '--apply'])
        self.assertRefused(rc, out, before, 'no image for the crownlte')

    def test_expect_device(self):
        before = self.f.snapshot()
        rc, out = self.run_it('--apply', '--expect-device', 'star2lte')
        self.assertRefused(rc, out, before, '--expect-device says star2lte')
        rc, out = self.run_it('--expect-device', 'starlte')
        self.assertEqual(rc, 0, out)

    # ---- protected partitions ----------------------------------------------------------------------------------------------------
    def test_refuses_a_zip_that_names_a_protected_partition(self):
        for part in ('EFS', 'RECOVERY', 'PARAM', 'RADIO', 'PERSISTENT', 'BOOT', 'USERDATA'):
            z = self.f.make_zip('bad-%s.zip' % part, system_part=part)
            before = self.f.snapshot()
            for mode in ('kernel-update', 'full'):
                rc, out = self.f.run(self.shell, args=['--zip', z, '--apply', '--mode', mode])
                self.assertRefused(rc, out, before)
                self.assertIn(part, out)

    def test_refuses_a_boot_that_is_a_protected_device_under_another_name(self):
        # by-name BOOT is a link to RECOVERY's block device (and, below, to EFS's)
        for target in ('RECOVERY', 'EFS', 'PARAM', 'RADIO'):
            self.f.reset_partitions()
            os.remove(self.f.part('BOOT'))
            os.symlink(self.f.part(target), self.f.part('BOOT'))
            before = {n: self.f.digest(n) for n in SIZES if n != 'BOOT'}
            rc, out = self.run_it('--apply')
            self.assertEqual(rc, 1, out)
            self.assertIn('Nothing was written.', out)
            self.assertTrue('same block device' in out or 'never written' in out or 'outside' in out or 'does not fit' in out, out)
            self.assertEqual({n: self.f.digest(n) for n in SIZES if n != 'BOOT'}, before, out)

    def test_refuses_when_the_table_is_not_the_manifests(self):
        for missing in ('RECOVERY', 'EFS', 'BOOT', 'SYSTEM', 'USERDATA'):
            self.f.reset_partitions()
            os.remove(self.f.part(missing))
            before = {n: self.f.digest(n) for n in SIZES if n != missing}
            rc, out = self.run_it('--apply')
            self.assertEqual(rc, 1, out)
            self.assertIn('no partition named %s' % missing, out)
            self.assertIn('Nothing was written.', out)
            self.assertEqual({n: self.f.digest(n) for n in SIZES if n != missing}, before)

    def test_refuses_sizes_outside_the_manifest(self):
        before = self.f.snapshot()
        with open(self.f.part('BOOT'), 'r+b') as f:
            f.truncate(1 * MIB)
        before = self.f.snapshot()
        rc, out = self.run_it('--apply')
        self.assertRefused(rc, out, before, 'outside')
        # a BOOT too small for the image
        self.f.reset_partitions()
        z = self.f.make_zip('big.zip')
        with open(self.f.part('BOOT'), 'r+b') as f:
            f.truncate(8 * MIB + 1)          # not whole blocks
        before = self.f.snapshot()
        rc, out = self.run_it('--apply')
        self.assertRefused(rc, out, before, 'whole number')

    def test_refuses_an_installer_prop_that_is_not_what_it_seems(self):
        # a corrupted installer.prop (the first member): the sizes are not numbers
        with open(self.f.zip, 'r+b') as f:
            data = f.read(4200)
            i = data.index(b'SYSTEM_SIZE=') + len(b'SYSTEM_SIZE=')
            f.seek(i)
            f.write(b'$(x)')
        before = self.f.snapshot()
        rc, out = self.run_it('--apply')
        self.assertRefused(rc, out, before, 'no usable system image entry')
        # not a zip at all
        junk = os.path.join(self.tmp, 'junk.zip')
        with open(junk, 'wb') as jf:
            jf.write(b'not a zip' * 100)
        rc, out = self.f.run(self.shell, args=['--zip', junk, '--apply'])
        self.assertRefused(rc, out, before, 'not one of Scion')

    # ---- hashes ------------------------------------------------------------------------------------------------------------------
    def flip(self, path, offset):
        with open(path, 'r+b') as f:
            f.seek(offset)
            b = f.read(1)
            f.seek(offset)
            f.write(bytes([b[0] ^ 0xFF]))

    def member_offset(self, key):
        with open(self.f.zip, 'rb') as f:
            prop = f.read(50 + 4096)[50:].decode()
        for line in prop.splitlines():
            if line.startswith(key + '='):
                return int(line.split('=')[1])
        raise KeyError(key)

    def test_refuses_a_damaged_boot_image(self):
        self.flip(self.f.zip, self.member_offset('BOOT_STARLTE_OFF') + 1000)
        before = self.f.snapshot()
        for mode in ('kernel-update', 'full'):
            rc, out = self.run_it('--apply', '--mode', mode)
            self.assertRefused(rc, out, before, 'boot image in the zip reads', 'adb push')
        # a dry run says the same: the verdict does not wait for --apply
        rc, out = self.run_it()
        self.assertRefused(rc, out, before, 'boot image in the zip reads')

    def test_refuses_a_damaged_system_image_in_full_mode(self):
        self.flip(self.f.zip, self.member_offset('SYSTEM_OFF') + 4000)
        before = self.f.snapshot()
        rc, out = self.run_it('--apply', '--mode', 'full')
        self.assertRefused(rc, out, before, 'system image in the zip reads')
        # the boot image of the same zip is fine, and a kernel update does not need the system member
        rc, out = self.run_it('--apply')
        self.assertEqual(rc, 0, out)

    def test_kernel_update_refuses_a_system_that_is_not_the_image(self):
        for what, data in (('android', rand(SYSTEM_IMAGE, 'android')), ('one byte off', None)):
            self.f.reset_partitions()
            with open(self.f.part('SYSTEM'), 'r+b') as f:
                if data is not None:
                    f.write(data)
                else:
                    f.seek(SYSTEM_IMAGE - 1)
                    f.write(b'\x00' if self.f.system[-1] != 0 else b'\x01')
            before = self.f.snapshot()
            rc, out = self.run_it('--apply')
            self.assertRefused(rc, out, before, 'SYSTEM on this phone is not the iOS system image', 'install the full zip first')

    def test_refuses_a_zip_whose_own_hash_differs(self):
        before = self.f.snapshot()
        rc, out = self.run_it('--apply', '--zip-sha256', '0' * 64)
        self.assertRefused(rc, out, before, "the zip's SHA-256 is")
        with open(self.f.zip, 'rb') as zf:
            right = hashlib.sha256(zf.read()).hexdigest()
        rc, out = self.run_it('--zip-sha256', right)
        self.assertEqual(rc, 0, out)
        rc, out = self.run_it('--zip-sha256', 'xyz')
        self.assertRefused(rc, out, before, '64 lower-case hex')

    # ---- failures after the first write ------------------------------------------------------------------------------------------
    def test_boot_that_reads_back_wrong_is_put_back(self):
        self.skip_if_busybox()
        # a dd that corrupts what it writes to BOOT: the readback fails, the copy must be put back
        shim = os.path.join(self.tmp, 'shim')
        os.makedirs(shim)
        real = shutil.which('dd')
        with open(os.path.join(shim, 'dd'), 'w') as f:
            f.write('#!/bin/sh\n"%s" "$@"\nrc=$?\n'
                    'for a in "$@"; do case "$a" in of=*BOOT) [ -f "%s/corrupt-once" ] && rm -f "%s/corrupt-once" && '
                    'printf Z | "%s" of="${a#of=}" bs=1 seek=100 conv=notrunc 2>/dev/null ;; esac; done\nexit $rc\n' % (real, self.tmp, self.tmp, real))
        os.chmod(os.path.join(shim, 'dd'), 0o755)
        open(os.path.join(self.tmp, 'corrupt-once'), 'w').close()
        before = self.f.snapshot()
        rc, out = self.run_it('--apply', path_prefix=shim)
        self.assertEqual(rc, 1, out)
        self.assertIn('reads back wrong', out)
        self.assertIn('BOOT is back as it was', out)
        self.assertUntouched(before, out)               # BOOT too: byte for byte
        # and the same without the corruption works
        rc, out = self.run_it('--apply', path_prefix=shim)
        self.assertEqual(rc, 0, out)

    def test_recovery_changing_during_the_install_is_a_failure(self):
        self.skip_if_busybox()
        shim = os.path.join(self.tmp, 'shim2')
        os.makedirs(shim)
        real = shutil.which('dd')
        # whatever writes BOOT also (wrongly) touches RECOVERY: the installer must notice
        with open(os.path.join(shim, 'dd'), 'w') as f:
            f.write('#!/bin/sh\n"%s" "$@"\nrc=$?\n'
                    'for a in "$@"; do case "$a" in of=*BOOT) printf Z | "%s" of="%s" bs=1 seek=10 conv=notrunc 2>/dev/null ;; esac; done\nexit $rc\n'
                    % (real, real, self.f.part('RECOVERY')))
        os.chmod(os.path.join(shim, 'dd'), 0o755)
        rc, out = self.run_it('--apply', path_prefix=shim)
        self.assertEqual(rc, 1, out)
        self.assertIn('RECOVERY changed during the install', out)

    # ---- the manifests -----------------------------------------------------------------------------------------------------------
    def test_manifests_exist_for_the_three_phones_and_list_what_is_never_written(self):
        for phone in PHONES:
            r = subprocess.run(self.shell.split() + [SCRIPT, '--print-manifest', phone], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            for w in ('BOOT RECOVERY EFS SYSTEM USERDATA', 'never written:', 'EFS', 'RPMB', 'PARAM', 'read before and after'):
                self.assertIn(w, r.stdout)
        r = subprocess.run(self.shell.split() + [SCRIPT, '--print-manifest', 'beyond1lte'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)

    def test_usage_errors(self):
        for args in (['--bogus'], ['--zip'], ['--mode', 'x', '--zip', self.f.zip], ['--apply']):
            rc, out = self.f.run(self.shell, args=args)
            self.assertNotEqual(rc, 0, out)
            self.assertNotIn('Done.', out)


def load_tests(loader, tests, pattern):
    suite = unittest.TestSuite()
    for sh in SHELLS:
        if shutil.which(sh.split()[0]) is None:
            print('test_scion_install: %s is not here, skipped' % sh, file=sys.stderr)
            continue
        cls = type('Tests_' + sh.replace(' ', '_'), (Tests,), {'shell': sh})
        suite.addTests(loader.loadTestsFromTestCase(cls))
    return suite


if __name__ == '__main__':
    unittest.main()
