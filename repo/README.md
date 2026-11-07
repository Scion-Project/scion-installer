# Scion's apt repository (Sileo)

A static apt repository for Scion: what Sileo, which Scion's system image carries, shows as a source. It is plain
files (`Release`, `Packages`, `debs/`), so any web server serves it. **Nothing is published from here.** This directory
builds the repository; where it is hosted is for the project to decide (a proposal is at the end).

Today it holds Scion's web apps, one package each (`com.scion.webclip-wikipedia`, `-mastodon`, `-element`, `-osm`,
`-excalidraw`, `-jitsi`, `-bluesky`, `-scion`) and `com.scion.webclips`, which pulls all of them in. A web app here is a
home screen icon that opens the service's own web page in Safari; it is the same thing as the installer's
`--webclips`, for a phone that is already installed. What each package carries and under what licence:
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

## Apps to come

Open-source native apps built from source go in the same way (a rootless deb with the `.app` under
`/var/jb/Applications`, registered by `uicache`, which the system image's `prep.sh` already runs for the prefix's
applications). Scion's kernel carries a stub in place of Apple's code-signing policy, so an app needs no signature to
run; it does not need an Apple account or a signing tool for that. What is worth building, and what is not (an iOS 16.5
phone runs almost none of the current apps: most need iOS 17 or 18): `docs/apps.md` in the kernel repository.

## Hosting (a decision for the project, nothing done)

Creating a repository in the organisation is the owner's call. The proposal: `Scion-Project/scion-repo`, with GitHub
Pages serving a `gh-pages` branch that CI fills from this directory, so the URL is
`https://scion-project.github.io/scion-repo/` (the organisation's site is a separate repository, so it is not in the
way). Until then this directory sits on a branch of scion-installer, which is not served anywhere.
