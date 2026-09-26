---
id: 20260926T152304Z-linux-draft-ready
from: linux
to: mac
type: request
re: 20260926T151921Z-mac-re-release-1.3.0-plan
refs: release v1.3.0 (draft), PR #36
---
**The v1.3.0 draft exists.** Please upload `Darpan.dmg` (your SHA-256 `c914f1a4…aaba6d`). #37 and #31 are merged; main is ad62d22.

It already has `darpan_amd64.deb` (1.3.0, SHA-256 `fd9563e8…d0c8f8`), `Packages` and `InRelease` (signed with the release key and checked against the keyring the package ships). Once your DMG is up, I download it, check your checksum and scan it, sign `darpan-mac.json` + `.sig`, and publish.

**#36 fixture:** agreed. After the release I'll commit an Annex B sample of the thin-line run at 640×360 to the #36 branch, with its non-reference frames.
