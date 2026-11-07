#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Scion dual-boot GPT plan, dry run. The GPT readers (header, entry array, protective MBR) are adapted from scion-blazer's
# tools/dualboot.py (MIT, Scion-Project); the plan is written fresh. scion-blazer's tools/gpt_plan.py states no licence, so it was
# read for its design only and none of it is copied.
"""Plan the Galaxy S9's dual-boot partition table. DRY RUN: reads a dump, prints the plan, writes nothing, anywhere.

Android keeps USERDATA, shrunk, as its /data (same first LBA); iOS gets SCIONROOT and SCIONVAR from USERDATA's old tail, and
an optional SCIONSTORE (the Android kernel and ramdisk, if they do not go in BOOT). Every other entry stays byte for byte.
It refuses a table where anything protected (EFS and the rest of PROTECTED) would move, and one it cannot read strictly.

  gpt-plan.py --image lun0.img                         a whole-LUN image (or a loop device's file)
  gpt-plan.py --head head.bin --tail tail.bin --total-lbas N     the first and last blocks of LUN 0 (dd, read only)
      [--root-gib 6] [--var-gib 6] [--store-mib 256] [--min-userdata-gib 8] [--json]

Blocks are 4096 bytes: the S9's UFS. The plan lists the blocks it would touch (the primary and backup headers and arrays) and
the SHA-256 of what is there now, to check a backup against. A rollback is writing those blocks back, from that backup.
"""
import argparse
import hashlib
import json
import os
import struct
import sys
import uuid
import zlib

BLOCK = 4096
ALIGN = (1 << 20) // BLOCK                      # 1 MiB
GPT = struct.Struct('<8sIIIIQQQQ16sQIII')
# Scion's own partition type: no OS knows it. uuid5 of a name, so every plan has the same one.
SCION_TYPE = uuid.uuid5(uuid.NAMESPACE_URL, 'scion:ios-owned-partition')
# What the plan may never move or touch. The first group is Samsung's (the map, section 2.3); the last two are Android's
# boot chain on LU0. Names are matched case-insensitively. The boot LUNs (S-Boot, CM, ECT) are not in LU0's table at all:
# one named here, if a dump shows it, is refused as a table that is not what this plan is for.
PROTECTED = ('EFS', 'CPEFS', 'PARAM', 'UP_PARAM', 'KEYSTORAGE', 'PERSISTENT', 'STEADY', 'BOTA0', 'BOTA1', 'DTB', 'DTBO',
             'SBOOT', 'S-BOOT', 'BL2', 'ECT', 'CM', 'UH', 'BOOT', 'RECOVERY')
NEW_PARTS = ('SCIONSTORE', 'SCIONROOT', 'SCIONVAR')


class Refused(ValueError):
    pass


def require(c, why):
    if not c:
        raise Refused(why)


def sha(b):
    return hashlib.sha256(b).hexdigest()


class Dump:
    """Blocks [0, len(head)) and [tail_lba, total) of the LUN, or the whole of an image."""

    def __init__(self, head, tail, total):
        require(len(head) % BLOCK == 0 and len(tail) % BLOCK == 0, 'a dump is not whole 4096-byte blocks')
        require(len(head) >= 6 * BLOCK and len(tail) >= 6 * BLOCK, 'the dumps must cover at least 6 blocks each end')
        require(len(head) // BLOCK < total - len(tail) // BLOCK, 'the dumps overlap')
        self.head, self.tail, self.total = head, tail, total
        self.tail_lba = total - len(tail) // BLOCK
        self.over = {}                           # lba -> new block (a plan's blocks, over the old)

    def read(self, lba, count=1):
        out = b''
        for i in range(lba, lba + count):
            require(0 <= i < self.total, 'read outside the LUN')
            if i in self.over:
                out += self.over[i]
            elif i < len(self.head) // BLOCK:
                out += self.head[i * BLOCK:(i + 1) * BLOCK]
            else:
                require(i >= self.tail_lba, 'LBA %d is not in the dumps' % i)
                o = (i - self.tail_lba) * BLOCK
                out += self.tail[o:o + BLOCK]
        return out

    @property
    def total_blocks(self):
        return self.total


def parse_header(data, at, blocks):
    require(len(data) == BLOCK, 'GPT header block is short')
    (sig, rev, size, crc, reserved, cur, alt, first, last, disk, array_lba, count, esize, acrc) = GPT.unpack_from(data)
    require(sig == b'EFI PART' and rev == 0x10000, 'invalid GPT signature or revision')
    require(GPT.size <= size <= BLOCK and reserved == 0, 'invalid GPT header shape')
    chk = bytearray(data[:size])
    chk[16:20] = b'\0' * 4
    require(zlib.crc32(chk) == crc, 'GPT header CRC mismatch at LBA %d' % at)
    require(not any(data[size:]), 'nonzero GPT header padding')
    require(cur == at and alt == (blocks - 1 if at == 1 else 1), 'GPT header geometry')
    require(6 <= first <= last <= blocks - 6 and disk != b'\0' * 16, 'invalid GPT usable interval or GUID')
    require(0 < count <= 4096 and esize == 128, 'unsupported GPT entry shape (this plan reads 128-byte entries)')
    nbytes = count * esize
    ablocks = (nbytes + BLOCK - 1) // BLOCK
    if at == 1:
        require(2 <= array_lba and array_lba + ablocks <= first, 'primary array overlaps usable blocks')
    else:
        require(last < array_lba and array_lba + ablocks <= at, 'backup array overlaps usable or header blocks')
    return dict(size=size, at=at, first=first, last=last, disk=disk, array_lba=array_lba, count=count, esize=esize, acrc=acrc,
                nbytes=nbytes, ablocks=ablocks)


def parse_entries(data, h):
    require(len(data) == h['ablocks'] * BLOCK, 'short GPT array')
    arr = data[:h['nbytes']]
    require(zlib.crc32(arr) == h['acrc'], 'GPT array CRC mismatch')
    parts, names, ids = [], set(), set()
    for i in range(h['count']):
        e = arr[i * 128:(i + 1) * 128]
        if e[:16] == b'\0' * 16:
            require(not any(e), 'an unused GPT entry has nonzero fields')
            continue
        first, last, attrs = struct.unpack_from('<QQQ', e, 32)
        require(h['first'] <= first <= last <= h['last'], 'a partition lies outside the usable interval')
        ident = str(uuid.UUID(bytes_le=e[16:32]))
        require(e[16:32] != b'\0' * 16 and ident not in ids, 'zero or duplicate partition GUID')
        ids.add(ident)
        try:
            name, _, tail = e[56:128].decode('utf-16-le').partition('\0')
        except UnicodeDecodeError:
            raise Refused('invalid UTF-16 partition name')
        require(not tail.strip('\0'), 'data after a partition name terminator')
        require(name and name not in names, 'empty or duplicate partition name')
        names.add(name)
        parts.append(dict(slot=i, name=name, first=first, last=last, attrs=attrs, raw=bytes(e),
                          type=str(uuid.UUID(bytes_le=e[:16])), unique=ident))
    ordered = sorted(parts, key=lambda p: p['first'])
    for a, b in zip(ordered, ordered[1:]):
        require(a['last'] < b['first'], 'overlapping partitions')
    return parts


def read_table(d):
    mbr = d.read(0)
    require(mbr[510:512] == b'\x55\xaa' and any(e[4] == 0xee for e in (mbr[446 + 16 * i:462 + 16 * i] for i in range(4))),
            'no protective MBR')
    p = parse_header(d.read(1), 1, d.total)
    b = parse_header(d.read(d.total - 1), d.total - 1, d.total)
    for k in ('first', 'last', 'disk', 'count', 'esize', 'acrc'):
        require(p[k] == b[k], 'primary and backup headers differ in ' + k)
    parr, barr = d.read(p['array_lba'], p['ablocks']), d.read(b['array_lba'], b['ablocks'])
    parts = parse_entries(parr, p)
    parse_entries(barr, b)
    require(parr[:p['nbytes']] == barr[:b['nbytes']], 'primary and backup arrays differ')
    return p, b, parts, parr


def mib(lbas):
    return lbas * BLOCK / (1 << 20)


def plan(d, root_gib=6.0, var_gib=6.0, store_mib=256.0, min_userdata_gib=8.0):
    """Returns (plan dict, {lba: new block}). Raises Refused. Reads d, changes nothing."""
    p, b, parts, parr = read_table(d)
    by = {x['name']: x for x in parts}
    require('USERDATA' in by, 'no partition named USERDATA')
    u = by['USERDATA']
    prot = [x for x in parts if x['name'].upper() in PROTECTED]
    require(all(x['last'] < u['first'] for x in prot),
            'a protected partition (%s) lies at or after USERDATA: it would have to move' %
            ', '.join(x['name'] for x in prot if x['last'] >= u['first']))
    require(all(x['last'] < u['first'] for x in parts if x is not u), 'USERDATA is not the last partition: its tail is not free')
    require(not any(n in by for n in NEW_PARTS), 'a Scion partition is there already: this table is planned')
    need_slots = 2 + (store_mib > 0)
    free = [i for i in range(p['count']) if parr[i * 128:i * 128 + 16] == b'\0' * 16]
    top = max(x['slot'] for x in parts)
    slots = [i for i in free if i > top][:need_slots]
    require(len(slots) == need_slots, 'not enough free entries after the last used one')
    # carve from the tail backwards, each start aligned down to 1 MiB; USERDATA's last LBA moves, its first does not
    end = u['last'] + 1
    carve = []
    for name, lbas in (('SCIONVAR', int(var_gib * (1 << 30)) // BLOCK), ('SCIONROOT', int(root_gib * (1 << 30)) // BLOCK),
                       ('SCIONSTORE', int(store_mib * (1 << 20)) // BLOCK)):
        if name == 'SCIONSTORE' and store_mib <= 0:
            continue
        require(lbas >= ALIGN, name + ' is smaller than 1 MiB')
        first = (end - lbas) // ALIGN * ALIGN
        carve.append((name, first, end - 1))
        end = first
    carve.reverse()                             # SCIONSTORE, SCIONROOT, SCIONVAR in LBA order
    new_u_last = end - 1
    require(new_u_last >= u['first'] and (new_u_last - u['first'] + 1) * BLOCK >= min_userdata_gib * (1 << 30),
            'USERDATA would be smaller than %g GiB (it is %.2f GiB now)' % (min_userdata_gib, mib(u['last'] - u['first'] + 1) / 1024))
    arr = bytearray(parr)
    arr[u['slot'] * 128 + 40:u['slot'] * 128 + 48] = struct.pack('<Q', new_u_last)
    added = []
    for slot, (name, first, last) in zip(slots, carve):
        ent = bytearray(128)
        ent[:16] = SCION_TYPE.bytes_le
        ent[16:32] = uuid.uuid5(uuid.UUID(bytes_le=p['disk']), name).bytes_le
        ent[32:56] = struct.pack('<QQQ', first, last, 0)
        ent[56:56 + 2 * len(name)] = name.encode('utf-16-le')
        arr[slot * 128:(slot + 1) * 128] = ent
        added.append(dict(slot=slot, name=name, first=first, last=last, unique=str(uuid.UUID(bytes_le=bytes(ent[16:32])))))
    arr = bytes(arr)
    over = {}
    for h, at in ((p, 1), (b, d.total - 1)):
        blk = bytearray(d.read(at))
        padded = arr[:h['nbytes']] + b'\0' * (h['ablocks'] * BLOCK - h['nbytes'])
        for i in range(h['ablocks']):
            over[h['array_lba'] + i] = padded[i * BLOCK:(i + 1) * BLOCK]
        blk[88:92] = struct.pack('<I', zlib.crc32(arr[:h['nbytes']]))
        blk[16:20] = b'\0' * 4
        blk[16:20] = struct.pack('<I', zlib.crc32(bytes(blk[:h['size']])))
        over[at] = bytes(blk)
    out = dict(total_lbas=d.total, disk_guid=str(uuid.UUID(bytes_le=p['disk'])), userdata=dict(
        first=u['first'], old_last=u['last'], new_last=new_u_last), added=added,
        touched=sorted(over), old_sha256={str(k): sha(d.read(k)) for k in sorted(over)})
    check(d, over, parts, out)
    return out, over


def check(d, over, old_parts, pl):
    """The plan, read back strictly and compared with what was there: refuses anything but the three intended changes."""
    require(all(k == 1 or k == d.total - 1 or 2 <= k < 2 + 64 or d.total - 1 - 64 <= k < d.total - 1 for k in over),
            'the plan would touch a block that is not a GPT header or array')
    d.over = over
    try:
        p, b, parts, _ = read_table(d)
    finally:
        d.over = {}
    new = {x['name']: x for x in parts}
    old = {x['name']: x for x in old_parts}
    require(set(new) - set(old) == {a['name'] for a in pl['added']}, 'the plan adds a partition that was not asked for')
    for n, x in old.items():
        if n == 'USERDATA':
            y = new[n]
            require(y['first'] == x['first'] and y['last'] <= x['last'] and y['attrs'] == x['attrs'] and
                    y['unique'] == x['unique'] and y['type'] == x['type'], 'USERDATA changed in more than its last LBA')
        else:
            require(new[n]['raw'] == x['raw'] and new[n]['slot'] == x['slot'], '%s would change' % n)
    for x in parts:
        if x['name'].upper() in PROTECTED:
            require(x['raw'] == old[x['name']]['raw'], 'protected %s would move' % x['name'])
    for a in pl['added']:
        require(a['first'] > pl['userdata']['new_last'] and a['first'] % ALIGN == 0 and a['last'] <= pl['userdata']['old_last'],
                a['name'] + ' is not inside the carved tail, aligned')


def render(pl, parts_old):
    L = ['GPT plan, DRY RUN (nothing is written): LUN of %d blocks of 4096, disk GUID %s' % (pl['total_lbas'], pl['disk_guid']), '']
    u = pl['userdata']
    L.append('  USERDATA   first LBA %d (kept)   last LBA %d -> %d   %.2f GiB -> %.2f GiB' % (
        u['first'], u['old_last'], u['new_last'], mib(u['old_last'] - u['first'] + 1) / 1024, mib(u['new_last'] - u['first'] + 1) / 1024))
    for a in pl['added']:
        L.append('  %-10s new  entry %-3d  LBA %d..%d   %.0f MiB   unique GUID %s' % (
            a['name'], a['slot'] + 1, a['first'], a['last'], mib(a['last'] - a['first'] + 1), a['unique']))
    L.append('  type GUID of the new ones: %s' % SCION_TYPE)
    L.append('  unchanged, byte for byte: %d entries, among them protected: %s' % (
        len(parts_old) - 1, ', '.join(x['name'] for x in parts_old if x['name'].upper() in PROTECTED) or 'none present'))
    L.append('')
    L.append('Blocks a write would touch (%d): %s' % (len(pl['touched']), ', '.join(map(str, pl['touched']))))
    L.append('Their SHA-256 now (check your backup of them against these before any write):')
    for k, h in pl['old_sha256'].items():
        L.append('  LBA %-10s %s' % (k, h))
    L.append('')
    L.append('USERDATA is shrunk: its file system (Android /data) is not valid past the new end. Back it up and make it again.')
    return '\n'.join(L)


def load(a):
    if a.image:
        require(not (a.head or a.tail), '--image is one or the other of --head/--tail')
        size = os.path.getsize(a.image)
        require(size % BLOCK == 0 and size > 12 * BLOCK, 'the image is not whole 4096-byte blocks')
        with open(a.image, 'rb') as f:
            head = f.read(64 * BLOCK)
            f.seek(size - 64 * BLOCK)
            tail = f.read()
        return Dump(head, tail, size // BLOCK)
    require(a.head and a.tail and a.total_lbas, 'give --image, or --head, --tail and --total-lbas')
    with open(a.head, 'rb') as h, open(a.tail, 'rb') as t:
        return Dump(h.read(), t.read(), a.total_lbas)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--image')
    ap.add_argument('--head')
    ap.add_argument('--tail')
    ap.add_argument('--total-lbas', type=int)
    ap.add_argument('--root-gib', type=float, default=6.0)
    ap.add_argument('--var-gib', type=float, default=6.0)
    ap.add_argument('--store-mib', type=float, default=256.0)
    ap.add_argument('--min-userdata-gib', type=float, default=8.0)
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args(argv)
    try:
        d = load(a)
        pl, _ = plan(d, a.root_gib, a.var_gib, a.store_mib, a.min_userdata_gib)
        print(json.dumps(pl, indent=1) if a.json else render(pl, read_table(d)[2]))
    except Refused as e:
        print('gpt-plan: REFUSED: %s' % e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
