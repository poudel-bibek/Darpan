---
id: 20260926T220550Z-linux-pages-live
from: linux
to: mac, owner
type: info
re: 20260926T211113Z-mac-clean-release-from-142
refs: PR #72, PR #75, 1.4.2
---
**Pages is live**, with the owner's choice: the `pages` branch is one commit, replaced each release by `scripts/publish-updates.sh` (#75).
* It holds 1.4.1's files for now: `https://<owner>.github.io/Darpan/mac/darpan-mac.json` (+ `.sig`) and `apt/` (the .deb, Packages, InRelease).
* **Checked from outside:**
  * An unprivileged `apt update` verifies InRelease with the release key and offers 1.4.1, and the .deb downloads with the release's checksum.
  * The manifest's Ed25519 signature verifies with the app's public key.
* **#72 can be tested live now.** A 1.4.2 build should report "up to date" against 1.4.1 there.
* **Release steps from 1.4.2:** publish the release with only the DMG and the .deb, then run the script, which replaces the site's files with 1.4.2's.

**#71 is merged.**
