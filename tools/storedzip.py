#!/usr/bin/env python3
# SPDX-License-Identifier: MIT-0
"""storedzip.py OUT.zip PROP_TEMPLATE NAME=FILE...: a zip TWRP can run, every member stored (not compressed), with no
Zip64 (each member and the whole under 4 GiB) and no extra fields, so that where each member's data begins is known in
advance. The first member is scion/installer.prop: PROP_TEMPLATE with @NAME_OFF@, @NAME_SIZE@ and @NAME_SHA256@
filled in for every other member NAME (its name upper-cased, up to the first '.', e.g. boot.img -> BOOT), padded to
4096 bytes, which is what the installer reads (update-binary: tail and head from those offsets)."""
import hashlib, os, struct, sys, time, zlib

PROP_NAME, PROP_SIZE = "scion/installer.prop", 4096
CHUNK = 16 << 20


def dos_time(t):
    lt = time.localtime(t)
    return ((lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec // 2),
            ((lt.tm_year - 1980) << 9) | (lt.tm_mon << 5) | lt.tm_mday)


def main():
    out, template, pairs = sys.argv[1], open(sys.argv[2]).read(), sys.argv[3:]
    members = [(n, p) for n, p in (a.split("=", 1) for a in pairs)]
    # where each data begins: the prop first (fixed size), then the members in order
    at = 30 + len(PROP_NAME) + PROP_SIZE
    values = {}
    for name, path in members:
        size = os.path.getsize(path)
        key = os.path.basename(name).split(".")[0].upper()
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for b in iter(lambda: f.read(CHUNK), b""):
                h.update(b)
        values.update({key + "_OFF": at + 30 + len(name), key + "_SIZE": size, key + "_SHA256": h.hexdigest()})
        at += 30 + len(name) + size
    if at > 0xFFFFFFFF - (1 << 20):
        sys.exit("storedzip.py: %d bytes is too much for a zip without Zip64" % at)
    prop = template
    for k, v in values.items():
        prop = prop.replace("@%s@" % k, str(v))
    if "@" in prop:
        sys.exit("storedzip.py: the template names something no member gives: %s" % prop[prop.index("@"):][:40])
    prop = prop.encode()
    if len(prop) > PROP_SIZE:
        sys.exit("storedzip.py: installer.prop is %d bytes, more than %d" % (len(prop), PROP_SIZE))
    prop += b"#" * (PROP_SIZE - len(prop) - 1) + b"\n"
    tm, dt = dos_time(time.time())
    central = []
    with open(out, "wb") as z:
        for name, src in [(PROP_NAME, None)] + members:
            offset, nb = z.tell(), name.encode()
            if src is None:
                data, crc, size = prop, zlib.crc32(prop), len(prop)
            else:
                data, size, crc = None, os.path.getsize(src), 0
                with open(src, "rb") as f:
                    for b in iter(lambda: f.read(CHUNK), b""):
                        crc = zlib.crc32(b, crc)
            z.write(struct.pack("<IHHHHHIIIHH", 0x04034B50, 10, 0, 0, tm, dt, crc, size, size, len(nb), 0) + nb)
            if data is not None:
                z.write(data)
            else:
                with open(src, "rb") as f:
                    for b in iter(lambda: f.read(CHUNK), b""):
                        z.write(b)
            mode = 0o100755 if name.endswith("update-binary") else 0o100644
            central.append(struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, (3 << 8) | 20, 10, 0, 0, tm, dt, crc, size,
                                       size, len(nb), 0, 0, 0, 0, mode << 16, offset) + nb)
        cd_at = z.tell()
        for c in central:
            z.write(c)
        z.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(central), len(central), z.tell() - cd_at, cd_at, 0))
    for k in sorted(values):
        if k.endswith("_OFF"):
            print("  %-40s data at %d, %d bytes" % (k[:-4], values[k], values[k[:-4] + "_SIZE"]))


main()
