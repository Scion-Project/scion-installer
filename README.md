# scion-packaging

Installers for Scion's phones. Each one is a single zip that a phone's recovery flashes: Scion's boot image and the iOS
system image, written to the phone's own partitions.

Only the tooling lives here. Everything an installer carries is built locally, from the kernel repository
([Scion-Project/hackios-xnu-kernel](https://github.com/Scion-Project/hackios-xnu-kernel)) and from your own IPSW:
- the iOS system image, which holds iOS's own files;
- the loader, which holds your iPhone's identity.

So an installer is yours, to hand on privately. It is never published and never committed; `.gitignore` keeps `*.zip`,
`*.img` and `*.apfs` out.

## Galaxy S9 (SM-G960F, `starlte`): `starlte/`

What the zip does in TWRP (`update-binary`, a shell script):
1. It checks the phone is a starlte / G960F.
2. It writes the iOS system image to `SYSTEM`, which replaces Android's system.
3. It writes Scion's boot image to `BOOT`.
4. It reads both back and checks each against its SHA-256.

Every member is stored uncompressed and copied straight out of the zip from a known offset (`installer.prop`, the zip's
first member). Many TWRP builds have no `unzip`, and 2.5 GB could not be unpacked into RAM anyway. The zip has no Zip64,
so TWRP's own zip reader opens it.

How it boots:
1. The S-Boot boot loader starts Silicium's UEFI, then Scion's loader, then the XNU kernel on six cores: the A55s 2
   and 3 and the four Exynos M3s (`cpus=6 bootcpu=2 m3_prep=3 pan=0`; S-Boot parks core 1, the loader keeps core 0).
   The kernel's own UFS driver takes the flash after a self-test against the loader's reads (`ufs=3`).
2. The kernel starts from the small root inside the boot image.
3. Its init mounts the system image from `/dev/ufs_SYSTEM`, makes it the root (`system_apfs=ufs_SYSTEM`), keeps
   `/private/var` in USERDATA when that holds an HFS Plus volume (`ufs_write=1 var_hfs=ufs_USERDATA_data`; a memory
   filesystem otherwise), and goes on as a RAM boot does: iOS's launchd, then SpringBoard.

The system image is read from the flash, never loaded into memory: the S9 has 4 GB.

### Build

In the kernel repository, with the S9's device repository synced (`tools/hakios-device.py sync starlte`):

```sh
make unpack IPSW=/path/to/iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw   # your own IPSW, once
make starlte_defconfig && make kernel && make loader          # the S9's kernel; the loader with your IPSW's identity
make images                                                   # userland/system.apfs (and a root.apfs, rebuilt below)
(source ./xnu-env.sh; cd userland && GL=1 NO_AIR=1 REST=1 ALONE=1 RC=rc.launchd bash build.sh)   # the small root
```

Then here:

```sh
SCION_KERNEL=/path/to/hackios-xnu-kernel starlte/mkinstaller.sh -s /path/to/hackios-xnu-kernel/userland/system.apfs
# -> out/scion-starlte-installer.zip; extra boot-args go at the end, over the defaults (e.g. fps_log=1, or wifi= to drop one)
```

`-p NAME` puts the system image on another partition, which must be at least as large as the image.

The boot-arguments are the S9's defaults: the kernel repository's `devices/starlte/configs/starlte.config`, which
`devices/starlte/mkimage.sh` puts on every image (hakios-starlte's README, "Defaults"). They turn on everything seen
working on the phone: six cores, the kernel's own UFS driver and a persistent `/private/var`, touch, keys, the battery
and vibration, the USB log and console, the GPU and both governors, the brightness slider, zero-copy display, the RTC,
the front camera, the speakers and Wi-Fi. The installer gives only `system_apfs=ufs_PARTITION`; extra boot-args given
to it go over the defaults (`name=value` replaces one, `name=` drops it). Diagnostics (`fps_log`, `systrace`, the
`*_probe` and `*_log` arguments) are never defaults.

**Keep what you build to yourself.** The zip carries iOS's own files from your IPSW, and the loader carries your
iPhone's identity. Do not publish it.

### Install

You need:
- a Galaxy S9, SM-G960F;
- an unlocked bootloader;
- TWRP in recovery.

Steps:
1. In TWRP, back up `Boot`, `System` and `EFS` (EFS holds the IMEI) and copy the backup off the phone.
2. Copy the zip to the phone (or use `adb sideload`), then Install > the zip > swipe.
3. Reboot > System.

To leave Scion, either:
- hold five fingers on the screen for 1.5 s. Control goes back to the loader, which keeps the log in RAM and restarts
  into TWRP;
- or force a restart with Vol Down + Power.

To get Android back, restore the `Boot` and `System` backups in TWRP.

## The Exynos 9810 Galaxys in one zip: S9, S9+, Note9 (`universal/`)

One zip for the Galaxy S9 (SM-G960F, `starlte`), the Galaxy S9+ (SM-G965F, `star2lte`) and the Galaxy Note9 (SM-N960F,
`crownlte`), with a boot image for each phone it was made for and one iOS system image. **Nobody has run Scion on an S9+ or a
Note9.** Their boot images borrow the S9's UEFI (no UEFI exists for them: hakios-star2lte and hakios-crownlte, README,
"The UEFI"), their first runs are tests, and their default boot-arguments start no driver of the board's.

What the zip does in TWRP (`universal/update-binary`, a shell script):
1. It finds out which phone it is on from the boot loader's id (`ro.boot.bootloader`: G960F..., G965F..., N960F...; the
   Duos FD models carry the F's), the model and the device name. Each that is set must name the same phone, and the boot
   loader's id or the model must be set. Anything else is refused before anything is written: another phone, a phone
   whose ids disagree, a phone the zip has no image for, and the Korean models (G960N, G965N, N960N) unless the zip was
   made with `-N` (their boards' device trees were never read).
2. It writes the iOS system image to `SYSTEM`, then that phone's boot image to `BOOT`, each read back and checked against
   its SHA-256.
3. Only a zip made with `-U`, and still named `*format-userdata*` when it is flashed, also formats `USERDATA` as HFS Plus
   for a persistent `/private/var` (**Android's data is lost**). USERDATA's size differs from phone to phone and with the
   storage (64 to 512 GB), so the volume is made at build time for each size given (`-u DEVICE=BLOCKS`, the kernel
   repository's `tools/mkdatavol.py --userdata`); a phone with a size the zip has no volume for is told the `-u` to build
   with, and nothing is written. Before writing, USERDATA must be unmounted and have no holder (no dm-crypt); after, the
   volume's head and tail are read back and checked.
4. It never writes `EFS`, `SEC_EFS`, `CPEFS`, `RADIO`, `RECOVERY` or the rest of the boot chain: they are refused by
   name, and by the block device they resolve to, before every write.

The boot-arguments:
- the S9's are its defaults, put on by the kernel repository's `devices/starlte/mkimage.sh` as for `starlte/mkinstaller.sh`,
  so the two installers never differ; the zip records the whole line the image carries;
- the S9+'s and the Note9's are `cpus=2 bootcpu=2 ufs=2 tmu=3 esslog=1 system_apfs=ufs_SYSTEM` (the SoC's, seen on the
  S9: two A55s, the flash through the loader, the thermal stop, the log kept for TWRP), with a 120 s time limit after
  which the run goes back to TWRP with its log. Touch, keys, battery, USB, GPU: add them one at a time with `-a`, as each
  phone's README orders them ("First runs").

### Build

In the kernel repository, with the three device repositories synced (`tools/hakios-device.py sync starlte star2lte
crownlte`), one kernel per phone:

```sh
make starlte_defconfig  && make kernel && cp hakios-kernel /tmp/k-starlte
make star2lte_defconfig && make kernel && cp hakios-kernel /tmp/k-star2lte
make crownlte_defconfig && make kernel && cp hakios-kernel /tmp/k-crownlte
make loader && make images && (source ./xnu-env.sh; cd userland && GL=1 NO_AIR=1 REST=1 ALONE=1 RC=rc.launchd bash build.sh)
```

Then here:

```sh
SCION_KERNEL=/path/to/hackios-xnu-kernel universal/mkinstaller.sh -s /path/to/hackios-xnu-kernel/userland/system.apfs \
    -k starlte=/tmp/k-starlte -k star2lte=/tmp/k-star2lte -k crownlte=/tmp/k-crownlte
# -> out/scion-exynos9810-installer.zip
# a persistent /private/var as well, for an S9 of 64 GB (USERDATA 13615227 blocks):
#   ... -U -u starlte=13615227      -> out/scion-exynos9810-installer-format-userdata.zip (MKFS=newfs_hfs on a Mac)
```

`universal/selftest.sh` (and `-U`, with `mkfs.hfsplus` or `MKFS=newfs_hfs`) makes the zip from stand-ins and runs it
against a pretend TWRP: each phone gets its own image, the refusals refuse, EFS and the rest stay untouched. It needs
nothing of Apple's or Samsung's. `SH="busybox sh"` runs update-binary under busybox's shell, as TWRP does.

**The system image is never in this repository or in the zip's sources.** It is built from your own IPSW, as for the S9
alone; the S9's CI job (hakios-starlte, `s9-installer`) downloads the IPSW from Apple's CDN at run time, builds it, and
uploads only an encrypted archive. That job does not make the universal zip yet: it clones only hakios-starlte, and it
would need the S9+'s and the Note9's repositories (public), two more kernels, and this script in place of
`starlte/mkinstaller.sh`.

The zip has no Zip64 (TWRP's reader): the system image and three boot images fit under 4 GiB with room to spare.
