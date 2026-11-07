# What is in the Scion repository, and under what terms

Rule: a package goes in only if its source is in this repository or the licence of what it carries is written down
here, with where the source is. Nothing of Apple's, no decrypted App Store app, no cracked paid app, no vendor firmware.
The repository carries no third-party binaries yet: Sileo and the Procursus bootstrap come from `apt.procurs.us`
(the installer fetches them, pinned by SHA-256; they are not mirrored here), and Havoc and Chariz are set up as
sources beside it.

## Packages in the repository

| Package | What it carries | Licence | Source |
|---|---|---|---|
| `com.scion.webclip-*` (8) | an `Info.plist` (title, address) and a 180 x 180 `icon.png` for one web app | MIT, with the rest of Scion's tooling | `userland/webclips/manifest.json` and `tools/mk-webclips.py` in scion-kernel; the icons are drawn by that script from plain shapes |
| `com.scion.webclips` | nothing; depends on the eight above | MIT | `repo/mkdebs.py` |

The icons are generated, not taken from anywhere: a coloured square and a generic pictogram (an open book, a speech
bubble, a map pin, a camera ...). They are deliberately not the services' logos: a logo is its owner's trademark (and
some carry licences of their own), and a home screen shortcut is no reason to ask. The web clips only point at each
service's own public web page; the packages ship none of their code.

## What may go in later (nothing here yet)

An open-source app, built from its source on a Mac or Linux machine without any Apple account and packaged as a
rootless deb under `/var/jb/Applications`, goes in with a row here saying: licence (SPDX), where the source is, the
commit built, the service's terms for third-party clients, and what was changed. The survey of candidates is
`docs/apps.md` in scion-kernel. A package whose licence needs its source offered (GPL, AGPL) carries a
`Source:` field and the patches as a second package or a link that stays up as long as the binary does.
