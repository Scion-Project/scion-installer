# What is in the Scion repository, and under what terms

Rule: a package goes in only if its source is in this repository or the licence of what it carries is written down
here, with where the source is. Nothing of Apple's, no decrypted App Store app, no cracked paid app, no vendor firmware.
The only third-party code it carries is the open-source apps below, built here from their source. Sileo and the Procursus bootstrap come from `apt.procurs.us`
(the installer fetches them, pinned by SHA-256; they are not mirrored here), and Havoc and Chariz are set up as
sources beside it.

## Packages in the repository

| Package | What it carries | Licence | Source |
|---|---|---|---|
| `com.scion.webclip-*` (8) | an `Info.plist` (title, address) and a 180 x 180 `icon.png` for one web app | MIT, with the rest of Scion's tooling | `userland/webclips/manifest.json` and `tools/mk-webclips.py` in scion-kernel; the icons are drawn by that script from plain shapes |
| `com.scion.webclips` | nothing; depends on the eight above | MIT | `repo/mkdebs.py` |
| `com.scion.app.puzzles` | `Puzzles.app`: Simon Tatham's Portable Puzzle Collection with Greg Hewgill's iOS front end, compiled here from source; its licence as `copyright` | MIT (upstream `LICENCE`) | https://github.com/ghewgill/puzzles at `01c3e382d9c7013f0bb4eb9f1ff2d19bb05d4241`, recipe `repo/apps/puzzles`; archive `sources/com.scion.app.puzzles_VERSION.tar.gz` beside the debs. No service, no network. Changed: build only (no Xcode: launch screen and icon catalog done in Info.plist), bundle id `com.scion.oss.puzzles`. Name and icons are upstream's; the app is free and the author's own App Store build is not displaced (different bundle id) |

The icons are generated, not taken from anywhere: a coloured square and a generic pictogram (an open book, a speech
bubble, a map pin, a camera ...). They are deliberately not the services' logos: a logo is its owner's trademark (and
some carry licences of their own), and a home screen shortcut is no reason to ask. The web clips only point at each
service's own public web page; the packages ship none of their code.

## Apps: what each row has to say

An open-source app, built from its source on a Mac or Linux machine without any Apple account and packaged as a
rootless deb under `/var/jb/Applications` (`repo/mkapps.py`, recipes in `repo/apps/`), goes in with a row here saying:
licence (SPDX), where the source is, the commit built, the service's terms for third-party clients, and what was
changed. The survey of candidates is `docs/apps.md` in scion-kernel. Every app deb carries `License`, `Source-Code`
and `Upstream-Commit` fields, its licence file and a `SOURCE` note in `/var/jb/usr/share/doc/PACKAGE/`, and
`mkapps.py` writes the corresponding source (upstream at the commit plus the recipe and its patches) to `sources/`
beside the debs, so a GPL or AGPL app's source is served as long as its binary is. A project's name or logo that is a
trademark (VLC, Firefox, Telegram ...) is replaced in a build that is not the project's own.
