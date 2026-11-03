# scion-packaging

Installers for Scion's phones. Each one is a single zip that a phone's recovery flashes: Scion's boot image and the iOS
system image, written to the phone's own partitions.

Only the tooling lives here. Everything an installer carries is built locally, from the kernel repository
([Scion-Project/hackios-xnu-kernel](https://github.com/Scion-Project/hackios-xnu-kernel)) and from your own IPSW:
- the iOS system image, which holds iOS's own files;
- the loader, which holds your iPhone's identity.

So an installer is yours, to hand on privately. It is never published and never committed; `.gitignore` keeps `*.zip`,
`*.img` and `*.apfs` out.

## Build it in one command: `build-installer.sh`

You need your own copy of iOS 16.5 (20F66) for the iPhone X: `iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw`, 6 165 698 198
bytes. Nothing here downloads it, and nothing here holds a key or decrypts anything. Then, in a checkout of this repository:

```sh
./build-installer.sh --ipsw ~/Downloads/iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw
# -> out/scion-starlte-installer.zip and out/scion-starlte-installer.zip.sha256, for the Galaxy S9
```

What it does, stopping at the first problem with what to do about it:
1. It checks that the machine has what the build needs, and lists everything that is missing at once.
2. It checks your IPSW: its size, its `BuildManifest.plist` (16.5, 20F66, iPhone10,3 and iPhone10,6) and its SHA-256.
3. It clones the kernel repository at the commit pinned in the script, into `./scion-build`. Then it checks out the
   device repositories at the revisions that commit's `devices/manifest.conf` pins (`tools/hakios-device.py sync`).
4. It runs the build in the **Build** sections below: `sysimage/unpack.sh`, the identity, one kernel for each phone, the
   loader, the small root and the system image. Then it runs `starlte/mkinstaller.sh`, or `universal/mkinstaller.sh`
   when you ask for anything other than the S9 alone.
5. It writes the zip and its SHA-256 to `./out`. Each step's log is in `scion-build/logs/`.

Options:
- `--device all`: the S9, the S9+ and the Note9 in one zip (`out/scion-exynos9810-installer.zip`). You can also give
  `star2lte`, `crownlte` or a list such as `starlte,crownlte`. **Nobody has run Scion on an S9+ or a Note9 yet.**
- `--format-userdata BLOCKS` (or `DEVICE=BLOCKS`, repeatable): the zip also formats USERDATA for a persistent
  `/private/var`. **This erases Android's data.** BLOCKS is your phone's USERDATA size in 4096-byte blocks. In TWRP's
  terminal: `echo $(( $(blockdev --getsize64 /dev/block/by-name/USERDATA) / 4096 ))`. For example, 13615227 is a 64 GB S9.
- Extra boot-arguments go after `--`, over the defaults: `./build-installer.sh --ipsw ... -- fps_log=1`.
- `--work DIR`, `--out DIR`, `--jobs N`, `--kernel-ref REF` (another kernel commit, for developers), `--skip-hash`.

Run it again after a failure and it picks up where it stopped. The clone, the unpacked IPSW, XNU's tree and Mesa are
kept in `scion-build`. To start clean, delete `scion-build`.

What it takes:

| | macOS (Apple silicon or Intel) | Linux (x86_64) |
|---|---|---|
| Tools | Xcode or its command-line tools (`xcode-select --install`), and `brew install sevenzip lld llvm bison meson ninja` | `sudo apt-get install build-essential git curl clang lld python3 python3-venv perl xz-utils flex bison m4 autoconf automake libtool-bin uuid-dev llvm meson ninja-build pkg-config 7zip` (Ubuntu 24.04; 7-Zip must be 23 or newer) |
| The iOS SDK the kernel is built against | fetched by `xnu-deps/setup.sh` | theos's Linux toolchain and `iPhoneOS16.5.sdk`, from `$THEOS` or `~/theos` when they are there, otherwise fetched into `scion-build/theos` |
| Disk | 20 GB free besides the IPSW: `scion-build` ends at about 10 GB (15 at most while it runs), the zip is 2.4 GB | the same, plus 1.5 GB for theos |
| Time, first run | 20 minutes on a Mac mini M1 that other builds were also using: about 1 to unpack, 5 for the kernel and its dependencies, 8 for Mesa, 4 for the images | not timed with an IPSW yet; the `--open` build (no Mesa, no system image) takes 6 minutes on GitHub's runners |

`--format-userdata` also needs `newfs_hfs` (part of macOS) or `mkfs.hfsplus` (Linux: `hfsprogs`).

**What comes out is yours alone.** The zip carries iOS's own files from your IPSW, and the loader carries your iPhone's
identity. Do not publish it, upload it or commit it. Install it as **Install** below says.

CI (`.github/workflows/build-installer.yml`) runs the whole script on Linux on every change, with `--open`. In that
mode there is no IPSW: the loader gets the placeholder identity (`xnuloader/mkidentity.sh --placeholder`), the small
root is the open one, and the system image is an empty stand-in. CI also runs `universal/selftest.sh` and checks that
the script refuses anything but the 20F66 IPSW. The zip that comes out installs, but iOS does not start from it.

### Troubleshooting

- **"this machine is missing what the build needs"**: run the command after each `->`, then run the script again.
  On a Mac, Homebrew's `lld` and `llvm` are keg-only. The script finds them in `/opt/homebrew/opt` itself, so you do not
  need to add them to `PATH`.
- **"N bytes, not 6165698198"** or **"SHA-256 ..., not ..."**: the IPSW is incomplete or a different file. Get it
  again. Only this one build works: `sysimage/select-system.py` knows its files.
- **"iOS x (y), not 16.5 (20F66)"** or **"for iPhoneN,M"**: a different IPSW. The S9 build needs the iPhone X's.
- **"... has local changes"**: something changed the kernel checkout in `scion-build`. Delete `scion-build`, or use
  another `--work`.
- **A step fails**: the script prints the last 60 lines of that step's log and the log's path (`scion-build/logs/`).
  - `kernel-*.log`: XNU's build always ends with some failures for kext symbol sets. `make kernel` ignores those and
    stops only on a real failure, which is the one to read.
  - `userland.log` while Mesa builds: the script also prints the first failure from Mesa's own logs. Mesa needs
    meson, ninja, `llvm-ar` (`brew install llvm`, Linux: `llvm`) and bison 3. macOS's `/usr/bin/bison` is 2.3
    (`invalid directive: '%code'`). The script finds Homebrew's keg-only bison by itself and uses it for this step only.
  - `unpack.log`: usually 7-Zip older than 23, or the disk filling up.
- **Disk**: the IPSW itself is 6.2 GB. In `scion-build`, measured on a Mac: the unpacked IPSW 5.7 GB, the images
  2.4 GB, XNU's tree 0.6 GB, its dependencies and Mesa 0.8 GB. While it unpacks, the IPSW's 4.7 GB root filesystem image
  is also there for a while. The zip is 2.4 GB. Once the zip is made you can delete `scion-build`, but the next build
  then starts from nothing.
- **Linux**: the script runs on x86_64 with theos's toolchain. CI runs it on Ubuntu 24.04, so that path is tested
  without an IPSW. The real build on Linux is the same as the one the S9's CI job runs (hakios-starlte,
  `s9-installer`), but nobody has timed it on a desk machine yet. arm64 Linux has no theos toolchain here.
- **Windows**: run it in WSL (Ubuntu 24.04), with `--work` in WSL's own filesystem (`~/...`), not under `/mnt/c`.

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
