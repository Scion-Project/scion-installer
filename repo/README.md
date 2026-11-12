<!-- SPDX-License-Identifier: MIT-0 -->
# Scion's apt repository (Sileo)

A static apt repository for Scion: what Sileo, which Scion's system image carries, shows as a source. It is plain
files (`Release`, `Packages`, `debs/`), so any web server serves it. **Nothing is published from here.** This directory
builds the repository; where it is hosted is for the project to decide (a proposal is at the end).

Today it holds Scion's web apps, one package each (`com.scion.webclip-wikipedia`, `-mastodon`, `-element`, `-osm`,
`-excalidraw`, `-jitsi`, `-bluesky`, `-scion`) and `com.scion.webclips`, which pulls all of them in. A web app here is a
home screen icon that opens the service's own web page in Safari; it is the same thing as the installer's
`--webclips`, for a phone that is already installed. And open-source native apps built from their source
(`com.scion.app.*`, [below](#open-source-apps)). What each package carries and under what licence:
[LICENSES.md](LICENSES.md).

## Build

```sh
git clone https://github.com/Scion-Project/scion-kernel.git         # the web-clip manifest and icon maker live there
repo/build.sh ./scion-kernel out/repo                               # needs dpkg-deb (Linux) and Python 3
repo/test.sh ./scion-kernel                                         # what CI runs; needs apt too
```

`out/repo` is the repository: `Release`, `Packages`, `Packages.gz`, `.xz`, `.bz2` and `debs/`. The same input gives
the same bytes. `repo/mkrepo.py` is pure Python, so the index can also be made on a Mac from debs built elsewhere.

`test.sh` builds twice and wants the same bytes, has **apt itself** read the index and plan the install of the whole set,
fetch a package with its checksums checked, and runs a package's postinst and postrm against a pretend phone. It has not
been run on a phone: nobody has added this repository to a Scion phone yet.

## Use (once it is hosted at URL)

- In Sileo: Sources, add `URL`. On the command line, in `/var/jb/etc/apt/sources.list.d/scion.sources`:

```
Types: deb
URIs: URL
Suites: ./
Components:
Trusted: yes
```

  `Trusted: yes` is because the repository is unsigned. `mkrepo.py --sign KEYID` makes `Release.gpg` and `InRelease`
  from a key the project makes and keeps; the script never creates a key. Until there is one, treat the repository
  as exactly as safe as the server it is on, and serve it over https.
- After installing a web app, a respring may be needed for the icon to show. Removing the package takes the icon away.
- Those packages put files in `/var/mobile/Library/WebClips`; with `/private/var` in memory (no `--format-userdata`)
  that is gone at the next boot, as everything installed is.

## Open-source apps

An F-Droid-like shelf: every app is built here from its upstream source at a pinned commit, never taken from the App
Store (no IPA, decrypted or not, ever goes in). Each is a rootless deb: the `.app` in `/var/jb/Applications`, its
licence and a note of where its source is in `/var/jb/usr/share/doc/PACKAGE/`, a postinst that runs
`uicache -p` and a prerm that runs `uicache -u`. Scion's kernel runs unsigned code, so no Apple account, certificate
or AppSync is involved; the build adds an ad-hoc signature (`ldid -S`, no entitlements) only so that tools which look
for a code directory find one. What is worth building (an iOS 16.5 phone runs almost none of the current apps):
`docs/apps.md` in the kernel repository.

```sh
THEOS=/path/to/theos APPS_WORK=/somewhere/outside/git repo/build.sh ./scion-kernel out/repo    # web apps + apps
python3 repo/mkapps.py --work WORK --out out/repo --only puzzles                                   # one app
```

`APPS_WORK` (`--work`) holds the upstream checkouts (`src/ID`) and the builds (`build/ID`): other people's code and
binaries, so it is outside every Scion repository and nothing from it is committed. `out/repo` gets, beside the
web apps, `debs/com.scion.app.*.deb`, `sources/PACKAGE_VERSION.tar.gz` (upstream at the commit plus the recipe: the
corresponding source a GPL app needs offered, served from the same place as its binary) and `apps.json` (name,
licence, source, commit, minimum iOS of each app, for a future App Library front end). Same input, same bytes.

| ID | Package | Licence | Upstream | Built on | Min iOS | On a phone |
|---|---|---|---|---|---|---|
| `puzzles` | `com.scion.app.puzzles` | MIT | [ghewgill/puzzles](https://github.com/ghewgill/puzzles) (iOS port of Simon Tatham's Puzzles) | Linux, Theos clang + iPhoneOS 16.5 SDK | 14.0 | installed from this repository with apt, registered, launches to its game list (S9+, 12 November 2026) |

### Adding an app

1. Check it is open source (an OSI licence on the code you build, not only on part of it), that its deployment
   target is 16.x or lower or can be lowered without code changes, and what it needs to build: Objective-C and C with
   the UI in code build on Linux; Swift, storyboards/XIBs (`ibtool`), asset catalogs beyond the icon (`actool`),
   CocoaPods or SwiftPM need Xcode on a Mac (`"host": "macos"`; build there with the same recipe, copy
   `build/ID/NAME.app` back and run `mkapps.py --no-build`).
2. Make `repo/apps/ID/app.json` (copy `puzzles`'): package `com.scion.app.ID`, version `UPSTREAM-scionN`, a bundle
   identifier of ours (`com.scion.oss.ID`, so it never stands in for the author's App Store app), licence as an SPDX
   id and the licence file's path in the source, `source.git` and the full `source.commit`, and in `changes` every
   way this build differs from upstream's.
3. Make `repo/apps/ID/build.sh SRC OUT` that leaves `OUT/NAME.app`. Patches, if any, go in `repo/apps/ID/` and are
   applied by `build.sh`, so they are in the source archive too.
4. A row here and in [LICENSES.md](LICENSES.md); a renamed name and icon when the project's name or logo is a
   trademark (VLC, Firefox, Telegram ...); for GPL and AGPL apps check the source archive is served next to the deb.
5. Test: `mkapps.py --only ID` twice gives the same deb; install on a phone from the served repository; it shows on
   the home screen and opens.

### Trying it from a phone on the LAN

`python3 -m http.server 8088 --directory out/repo` serves it. A WSL2 with mirrored networking does not take inbound
connections from the LAN unless the Hyper-V firewall lets it (`Set-NetFirewallHyperVVMSetting` / a
`New-NetFirewallHyperVRule` for the port, the owner's call); without that, a reverse tunnel over the phone's SSH works:
`ssh -N -R 8088:127.0.0.1:8088 root@PHONE`, and the source on the phone is `http://127.0.0.1:8088/`.

## Hosting (a decision for the project, nothing done)

Creating a repository in the organisation is the owner's call. The proposal: `Scion-Project/scion-repo`, with GitHub
Pages serving a `gh-pages` branch that CI fills from this directory, so the URL is
`https://scion-project.github.io/scion-repo/` (the organisation's site is a separate repository, so it is not in the
way). Until then this directory sits on a branch of scion-installer, which is not served anywhere.
