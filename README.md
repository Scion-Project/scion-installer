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
1. The S-Boot boot loader starts Silicium's UEFI, then Scion's loader, then the XNU kernel on the A55 cores 2 and 3
   (`cpus=2 bootcpu=2`, the installer's default; S-Boot parks core 1). The loader stays on core 0 and reads the flash
   for the kernel through the UEFI's UFS driver (`ufs=2`). Six cores (the four Exynos M3s as well) have been seen
   running with `cpus=6 bootcpu=2 m3_prep=3 pan=0`. That is not the installer's default yet: see
   [hakios-starlte's README, "The cores"](https://github.com/Scion-Project/hakios-starlte#the-cores).
2. The kernel starts from the small root inside the boot image.
3. Its init mounts the system image from `/dev/ufs_SYSTEM`, makes it the root (`system_apfs=ufs_SYSTEM`), and goes on
   as a RAM boot does: iOS's launchd, then SpringBoard.

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
# -> out/scion-starlte-installer.zip; extra boot-args go at the end (e.g. mali=9, abox=8 max98512=3)
```

`-p NAME` puts the system image on another partition, which must be at least as large as the image.

The installer's default boot-arguments (`starlte/mkinstaller.sh`) turn on what has been seen working on the phone:
touch (`s6sy761=1`), the battery and vibration (`max77705=1 max77705_haptic=1`), the USB log and console
(`usb_gadget=5 max77705_usbsw=1`), the GPU (`mali=9`) and the A55s' clock (`cpufreq_lit=1794000`). They also set `panel=1`, `tmu=3` (the run ends
at 110 °C) and `esslog=1` (the log kept for TWRP). Brightness from
iOS's slider (`backlight=2`) and the cameras (`cam_s9=N`) are written but not yet confirmed or tested on the phone, and
are not in the default.

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
