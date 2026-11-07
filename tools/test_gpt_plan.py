#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host tests for tools/gpt-plan.py: synthetic S9-shaped GPTs (4096-byte blocks), no phone and no root.
The plan's own strict read-back and diff (check() in the tool) are what is tested; `sgdisk -v` on a 4096-byte-sector loop device is NOT run
here (it needs root, and sgdisk on a plain file assumes 512-byte sectors and sees no table)."""
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('gpt_plan', os.path.join(HERE, 'gpt-plan.py'))
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)
B = gp.BLOCK
DISK = uuid.UUID('11111111-2222-3333-4444-555555555555')
LINUX = uuid.UUID('0fc63daf-8483-4772-8e79-3d69d8477de4')

# name, MiB; an S9-like LU0: Samsung's first, Android's, USERDATA last
LAYOUT = [('EFS', 16), ('CPEFS', 16), ('PARAM', 8), ('UP_PARAM', 8), ('KEYSTORAGE', 4), ('PERSISTENT', 4), ('STEADY', 4), ('BOTA0', 8),
          ('BOTA1', 8), ('DTB', 8), ('DTBO', 8), ('BOOT', 64), ('RECOVERY', 64), ('SYSTEM', 4864), ('VENDOR', 725), ('ODM', 700),
          ('USERDATA', 51000)]


class Sparse(dict):
    """LBA -> block; the rest of the LUN is zeros."""

    def __init__(self, total):
        super().__init__()
        self.total = total

    def copy(self):
        c = Sparse(self.total)
        c.update(self)
        return c


def build(layout=LAYOUT, total=None, count=128, tail_gap_mib=1):
    """A whole LUN as bytes: protective MBR, primary header and array, partitions packed from 1 MiB, backup array and header."""
    ents = bytearray(count * 128)
    lba = 256                                   # 1 MiB
    last_end = 0
    for i, (n, m) in enumerate(layout):
        first, last = lba, lba + m * 256 - 1
        e = bytearray(128)
        e[:16] = LINUX.bytes_le
        e[16:32] = uuid.uuid5(DISK, 'x' + n).bytes_le
        e[32:56] = struct.pack('<QQQ', first, last, 0)
        e[56:56 + 2 * len(n)] = n.encode('utf-16-le')
        ents[i * 128:(i + 1) * 128] = e
        lba, last_end = last + 1, last
    ablocks = count * 128 // B
    total = total or last_end + 1 + tail_gap_mib * 256 + ablocks + 1
    img = Sparse(total)
    mbr = bytearray(B)
    mbr[446 + 4] = 0xee
    struct.pack_into('<II', mbr, 446 + 8, 1, min(total - 1, 0xffffffff))
    mbr[510:512] = b'\x55\xaa'
    img[0] = mbr

    def header(at, alt, array_lba):
        h = bytearray(B)
        struct.pack_into('<8sIIIIQQQQ16sQIII', h, 0, b'EFI PART', 0x10000, 92, 0, 0, at, alt, 6, total - 1 - ablocks - 1, DISK.bytes_le,
                         array_lba, count, 128, zlib.crc32(bytes(ents)))
        struct.pack_into('<I', h, 16, zlib.crc32(bytes(h[:92])))
        return h
    img[1] = header(1, total - 1, 2)
    for i in range(ablocks):
        img[2 + i] = ents[i * B:(i + 1) * B]
        img[total - 1 - ablocks + i] = ents[i * B:(i + 1) * B]
    img[total - 1] = header(total - 1, 1, total - 1 - ablocks)
    return img


def blob(img, lo, hi):
    return b''.join(img.get(i, bytes(B)) for i in range(lo, hi))


def dump(img):
    return gp.Dump(blob(img, 0, 64), blob(img, img.total - 64, img.total), img.total)


def rd(p):
    with open(p, 'rb') as f:
        h = f.read(64 * B)
        f.seek(-64 * B, 2)
        return h, f.read()


class T(unittest.TestCase):
    def test_plan_and_sgdisk(self):
        img = build()
        d = dump(img)
        pl, over = gp.plan(d)
        names = [a['name'] for a in pl['added']]
        self.assertEqual(names, ['SCIONSTORE', 'SCIONROOT', 'SCIONVAR'])
        u = pl['userdata']
        self.assertEqual(u['first'], 256 + sum(m for n, m in LAYOUT[:-1]) * 256)       # USERDATA keeps its first LBA
        self.assertLess(u['new_last'], u['old_last'])
        self.assertEqual(pl['added'][-1]['last'], u['old_last'])                         # SCIONVAR at the tail
        for a in pl['added']:
            self.assertEqual(a['first'] % 256, 0)
        self.assertEqual(sorted(over), pl['touched'])
        self.assertTrue(set(over) <= {1, img.total - 1} | set(range(2, 6)) | set(range(img.total - 5, img.total)))
        self.assertEqual(dump(img).read(1), d.read(1))                                   # the plan did not change its input

    def test_no_store(self):
        pl, _ = gp.plan(dump(build()), store_mib=0)
        self.assertEqual([a['name'] for a in pl['added']], ['SCIONROOT', 'SCIONVAR'])

    def test_protected_after_userdata(self):
        lay = LAYOUT[:-1] + [('USERDATA', 51000), ('ECT', 8)]
        with self.assertRaises(gp.Refused) as c:
            gp.plan(dump(build(lay)))
        self.assertIn('protected', str(c.exception))

    def test_userdata_not_last(self):
        lay = LAYOUT[:-1] + [('USERDATA', 51000), ('HIDDEN', 8)]
        with self.assertRaises(gp.Refused):
            gp.plan(dump(build(lay)))

    def test_no_userdata(self):
        with self.assertRaises(gp.Refused):
            gp.plan(dump(build(LAYOUT[:-1])))

    def test_too_small(self):
        lay = LAYOUT[:-1] + [('USERDATA', 9000)]
        with self.assertRaises(gp.Refused):
            gp.plan(dump(build(lay)))

    def test_already_planned(self):
        pl, over = gp.plan(dump(build()))
        img = build()
        img.update(over)
        with self.assertRaises(gp.Refused):
            gp.plan(dump(img))

    def test_bad_crc(self):
        for lba, off in ((2, 5), (1, 30)):
            img = build()
            blk = bytearray(img[lba])
            blk[off] ^= 1
            img[lba] = bytes(blk)
            with self.assertRaises(gp.Refused):
                gp.plan(dump(img))

    def test_backup_differs(self):
        img = build()
        blk = bytearray(img[img.total - 3])
        blk[7] ^= 1                                      # inside the backup array
        img[img.total - 3] = bytes(blk)
        with self.assertRaises(gp.Refused):
            gp.plan(dump(img))

    def test_cli_writes_nothing(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'lun0.img')
            im = build()
            with open(p, 'wb') as f:
                f.truncate(im.total * B)
                for k, v in im.items():
                    f.seek(k * B)
                    f.write(v)
            st = os.stat(p)
            before = rd(p)
            r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'gpt-plan.py'), '--image', p], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('DRY RUN', r.stdout)
            self.assertIn('SCIONVAR', r.stdout)
            after = rd(p)
            self.assertEqual(after, before)
            self.assertEqual(os.stat(p).st_mtime_ns, st.st_mtime_ns)
            self.assertEqual(sorted(os.listdir(t)), ['lun0.img'])
            r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'gpt-plan.py'), '--image', p, '--json'], capture_output=True, text=True)
            self.assertIn('"touched"', r.stdout)

    def test_no_write_in_source(self):
        src = open(os.path.join(HERE, 'gpt-plan.py')).read()
        for bad in ("open(a.image, 'wb'", "'wb'", "'r+b'", "os.write", ".write("):
            self.assertNotIn(bad, src.replace('mbr', ''))


if __name__ == '__main__':
    unittest.main()
