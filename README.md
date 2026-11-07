# scion-installer

Installers for Scion's phones. Each one is a single zip that a phone's recovery flashes: Scion's boot image and the iOS
system image, written to the phone's own partitions.

Only the tooling lives here. Everything an installer carries is built locally, from the kernel repository
([Scion-Project/scion-kernel](https://github.com/Scion-Project/scion-kernel)) and from your own IPSW:
- the iOS system image, which holds iOS's own files;
- the loader, which holds your iPhone's identity.

So an installer is yours, to hand on privately. It is never published and never committed; `.gitignore` keeps `*.zip`,
`*.img` and `*.apfs` out.

## Build it in one command: `build-installer.sh`

You need your own copy of iOS 16.5 (20F66) for the iPhone X: `iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw`, 6 165 698 198
bytes. Nothing here downloads it, and nothing here holds a key or decrypts anything. Then, in a checkout of this repository:

```sh
./build-installer.sh --ipsw ~/Downloads/iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw
# -> out/scion-exynos9810-installer.zip and its .sha256, for the Galaxy S9, S9+ and Note9
```

What it does, stopping at the first problem with what to do about it:
1. It checks that the machine has what the build needs, and lists everything that is missing at once.
2. It checks your IPSW: its size, its `BuildManifest.plist` (16.5, 20F66, iPhone10,3 and iPhone10,6) and its SHA-256.
3. It clones the kernel repository at the commit pinned in the script, into `./scion-build`. Then it checks out the
   device repositories at the revisions that commit's `devices/manifest.conf` pins (`tools/hakios-device.py sync`).
4. It runs the build in the **Build** sections below: `sysimage/unpack.sh`, the identity, one kernel for each phone, the
   loader, the small root and the system image, with Sileo in it (**Sileo**, below). Then it runs
   `universal/mkinstaller.sh`.
5. It writes the zip and its SHA-256 to `./out`. Each step's log is in `scion-build/logs/`.

Options:
- `--device`: every build is the universal zip, with all three phones unless you give `starlte`, `star2lte`, `crownlte` or
  a list such as `starlte,crownlte`. **Nobody has run Scion on an S9+ or a Note9 yet.**
- `--no-sileo`: leave Sileo and the Procursus bootstrap out of the system image.
- `--webclips`: web apps on the home screen from the first boot (off by default): Wikipedia, Mastodon, Element,
  OpenStreetMap, Excalidraw, Jitsi Meet, Bluesky and Scion's own page, as the web clips that Safari's "Add to Home
  Screen" makes (no configuration profile, no account). The icons are drawn by the kernel repository's
  `tools/mk-webclips.py`, not the sites' logos. They open in Safari; nothing has been tried on a phone yet. It needs a
  kernel revision that has `WEBCLIPS=1` (`--kernel-ref`), and refuses one that does not.
- `--format-userdata BLOCKS` (or `DEVICE=BLOCKS`, repeatable): the zip also formats USERDATA for a persistent
  `/private/var`. **This erases Android's data.** BLOCKS is your phone's USERDATA size in 4096-byte blocks. In TWRP's
  terminal: `blockdev --getsize64 /dev/block/by-name/USERDATA | awk '{ printf "%.0f\n", $1 / 4096 }'` (its shell's own
  arithmetic stops at 32 bits). For example, 13615227 is a 64 GB S9.
- Extra boot-arguments go after `--`, over the defaults: `./build-installer.sh --ipsw ... -- fps_log=1`.
- For the S9 it also gives `rtc_pmic= shub=6 abox_mic=1 bt=7` over the defaults, the daily's line (Bluetooth, the sensors
  and the microphone in iOS; `rtc_pmic=` makes the room), and builds the small root with `BT=1 DEVICE=starlte` (Bluetooth's
  jobs and the firmware of the S9's repository). By hand, give the same: `-a "starlte=rtc_pmic= shub=6 abox_mic=1 bt=7"` for
  `universal/mkinstaller.sh`.
- `--work DIR`, `--out DIR`, `--jobs N`, `--kernel-ref REF` (another kernel commit, for developers), `--skip-hash`.

Run it again after a failure and it picks up where it stopped. The clone, the unpacked IPSW, XNU's tree and Mesa are
kept in `scion-build`. To start clean, delete `scion-build`.

What it takes:

| | macOS (Apple silicon or Intel) | Linux (x86_64) |
|---|---|---|
| Tools | Xcode or its command-line tools (`xcode-select --install`), and `brew install sevenzip lld llvm bison meson ninja zstd` | `sudo apt-get install build-essential git curl zstd clang lld python3 python3-venv perl xz-utils flex bison m4 autoconf automake libtool-bin uuid-dev llvm meson ninja-build pkg-config 7zip` (Ubuntu 24.04; 7-Zip must be 23 or newer) |
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
  without an IPSW. The real build on Linux is the same as the one the S9's CI job runs (scion-starlte,
  `s9-installer`), but nobody has timed it on a desk machine yet. arm64 Linux has no theos toolchain here.
- **Windows**: run it in WSL (Ubuntu 24.04), with `--work` in WSL's own filesystem (`~/...`), not under `/mnt/c`.

## The Exynos 9810 Galaxys in one zip: S9, S9+, Note9 (`universal/`)

One zip for the Galaxy S9 (SM-G960F, `starlte`), the Galaxy S9+ (SM-G965F, `star2lte`) and the Galaxy Note9 (SM-N960F,
`crownlte`), with a boot image for each phone it was made for and one iOS system image. **Nobody has run Scion on an S9+ or a
Note9.** Their boot images borrow the S9's UEFI (no UEFI exists for them: scion-star2lte and scion-crownlte, README,
"The UEFI"), their first runs are tests, and their default boot-arguments start no driver of the board's.

What the zip does in TWRP (`universal/update-binary`, a shell script):
1. It finds out which phone it is on from the boot loader's id (`ro.boot.bootloader`: G960F..., G965F..., N960F...; the
   Duos FD models carry the F's), the model and the device name. Each that is set must name the same phone, and an id
   must be set: the boot loader's, or a model given as `SM-...`. The official TWRP gives the model as the phone's name
   (`Galaxy S9`): the name must agree, and it is not enough alone, since the Snapdragon S9 has it too. Anything else is
   refused before anything is written: another phone, a phone whose ids disagree, a phone the zip has no image for, and
   the Korean models (G960N, G965N, N960N) unless the zip was made with `-N` (their boards' device trees were never read).
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
- the S9's are its defaults, the kernel repository's `devices/starlte/configs/starlte.config`, put on by its
  `devices/starlte/mkimage.sh`: six cores, the kernel's own UFS driver and a persistent `/private/var`, touch, keys, the
  battery and vibration, the USB log and console, the GPU and both governors, the brightness slider, zero-copy display,
  the RTC, the front camera, the speakers and Wi-Fi. Extra boot-args go over them (`name=value` replaces one, `name=` drops
  it). Diagnostics are never defaults. The zip records the whole line the image carries;
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
make loader && make images && (source ./xnu-env.sh; cd userland && GL=1 NO_AIR=1 REST=1 ALONE=1 RC=rc.launchd BT=1 DEVICE=starlte bash build.sh)
```

Then here:

```sh
SCION_KERNEL=/path/to/scion-kernel universal/mkinstaller.sh -s /path/to/scion-kernel/userland/system.apfs \
    -k starlte=/tmp/k-starlte -k star2lte=/tmp/k-star2lte -k crownlte=/tmp/k-crownlte
# -> out/scion-exynos9810-installer.zip
# a persistent /private/var as well, for an S9 of 64 GB (USERDATA 13615227 blocks):
#   ... -U -u starlte=13615227      -> out/scion-exynos9810-installer-format-userdata.zip (MKFS=newfs_hfs on a Mac)
```

`universal/selftest.sh` (and `-U`, with `mkfs.hfsplus` or `MKFS=newfs_hfs`) makes the zip from stand-ins and runs it
against a pretend TWRP: each phone gets its own image, the refusals refuse, EFS and the rest stay untouched. It needs
nothing of Apple's or Samsung's. `SH="busybox sh"` runs update-binary under busybox's shell, as TWRP does.

**The system image is never in this repository or in the zip's sources.** It is built from your own IPSW. The S9's CI
job (scion-starlte, `s9-installer`) downloads the IPSW from Apple's CDN at run time, builds it, and uploads only an
encrypted archive.

The zip has no Zip64 (TWRP's reader): the system image and three boot images fit under 4 GiB with room to spare.

### How it boots

On the S9, whose kernel starts more than the other two:
1. The S-Boot boot loader starts Silicium's UEFI, then Scion's loader, then the XNU kernel on six cores: the A55s 2
   and 3 and the four Exynos M3s (`cpus=6 bootcpu=2 m3_prep=3 pan=0`; S-Boot parks core 1, the loader keeps core 0).
   The kernel's own UFS driver takes the flash after a self-test against the loader's reads (`ufs=3`).
2. The kernel starts from the small root inside the boot image.
3. Its init mounts the system image from `/dev/ufs_SYSTEM`, makes it the root (`system_apfs=ufs_SYSTEM`), keeps
   `/private/var` in USERDATA when that holds an HFS Plus volume (`ufs_write=1 var_hfs=ufs_USERDATA_data`; a memory
   filesystem otherwise), and goes on as a RAM boot does: iOS's launchd, then SpringBoard.

The system image is read from the flash, never loaded into memory: the S9 has 4 GB.

### Install

You need:
- a Galaxy S9 (SM-G960F), S9+ (SM-G965F) or Note9 (SM-N960F);
- an unlocked bootloader;
- TWRP in recovery.

Steps:
1. In TWRP, back up `Boot`, `System` and `EFS` (EFS holds the IMEI) and copy the backup off the phone.
2. Put the zip where TWRP can read it ("Getting the zip onto the phone", below), then Install > the zip > swipe.
3. Reboot > System.

To leave Scion, either:
- hold five fingers on the screen for 1.5 s. Control goes back to the loader, which keeps the log in RAM and restarts
  into TWRP;
- or force a restart with Vol Down + Power.

To get Android back, restore the `Boot` and `System` backups in TWRP.

### Getting the zip onto the phone

The zip is over 2 GiB, which decides how:
- **Not `adb sideload`.** The recovery's sideload host keeps the size in 32 bits: it saw -1697321647 bytes, and nothing
  was written.
- A microSD card is simplest: copy the zip to it on a computer, then Install > Select Storage > Micro SDCard. The card must
  hold a file over 2 GiB, which FAT32 can, up to 4 GiB.
- `adb push ZIP /sdcard/`, when TWRP has internal storage mounted and 3 GB free in it.
- With neither (`USERDATA` already HFS Plus, or Android's encrypted so that TWRP cannot read it), memory: `/tmp` is about
  1.8 GB until it is made bigger, and the phone has room for the zip while it installs:

  ```sh
  adb shell mount -o remount,size=3G /tmp
  adb push scion-exynos9810-installer.zip /tmp/
  adb shell twrp install /tmp/scion-exynos9810-installer.zip
  ```

  A copy in memory is gone at the next restart, and nothing is left behind.

## Sileo

The zip's system image carries [Sileo](https://github.com/Sileo/Sileo) (BSD-2-Clause) and the
[Procursus](https://github.com/ProcursusTeam/Procursus) rootless bootstrap (each package under its own licence). The build
fetches both from `apt.procurs.us`, checked against the SHA-256 pinned in the kernel repository's `tools/mk-jb.sh`. Neither
is in any repository, and neither is run at build time. No tweak injection, no App Store and no Apple ID are involved.

- **With a kept `/private/var`** (`USERDATA` formatted as HFS Plus, by a zip made with `--format-userdata` or as the S9's
  README says): at the first boot a background job copies the prefix to `/private/var/jb`, about 120 MB. Sileo's icon then
  appears on the second home screen page. What you install lasts across reboots and across later zips, which never touch
  `/private/var/jb`. To start over, delete it, and the next boot copies it again.
- **With `/private/var` in memory** (no such volume; so far also the S9+ and the Note9): skipped. No copy, no icon, and the
  boot does nothing for it. Sileo only appears on a phone that has somewhere to keep it.
- A failed copy costs a line on the console; iOS comes up the same, and the next boot tries again.

The default sources are Procursus, Havoc and Chariz. Join Wi-Fi in Settings first: Sileo refreshes them over the network.
