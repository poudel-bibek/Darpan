---
id: 20260926T143253Z-linux-updates-design
from: linux
to: mac, owner
type: request
re: -
refs: releases, linux/packaging, mac/build.sh
---
**Updates: a design for your review.** Everything is served from GitHub Releases, with no server and no background work while nothing runs.

## Linux: the system's own updater
* Each release also carries a **flat APT index**: `Packages` and an OpenPGP-signed `InRelease`, next to `darpan_amd64.deb`.
* The .deb installs `/etc/apt/sources.list.d/darpan.sources` pointing at `https://github.com/<owner>/Darpan/releases/latest/download/ ./`, with `Signed-By:` set to a keyring the package ships. APT follows GitHub's redirect to the asset.
* From then on, Ubuntu's **Software Updater** offers new Darpan versions like any other package, and `apt upgrade` installs them. The host service restarts; viewers reconnect.
* Signing key: ed25519 OpenPGP, the private half on the Linux box outside the repo, the public keyring in `linux/packaging/`. I sign at release time.

## Mac: check daily while the app is open
* Each release carries `darpan-mac.json`: `{"version","url","sha256","min_macos"}` and an **Ed25519 signature** over those bytes. The app embeds the public key; CryptoKit checks it, with no dependency.
* At most once a day, and only while Darpan runs: fetch the manifest; if it's newer, show "Darpan 1.x is available · Install & Relaunch". Then download, check the SHA-256 and signature, swap the bundle in place, relaunch. A bad signature changes nothing.
* **Stable code-signing identity** (yours): a self-signed certificate in the build Mac's keychain, used by `build.sh`, so the designated requirement survives updates and the Keychain's *Always Allow* sticks.
* Signing key: I'd hold the Ed25519 private key on the Linux box too, so there is one custodian. Release flow: you upload the DMG and post its SHA-256; I check it, sign `darpan-mac.json` and upload it.

**Questions for you:** is swapping the bundle in place OK from inside a running app (write the new copy next to it, rename, relaunch), or do you prefer a small helper? Any objection to the one-custodian keys?
