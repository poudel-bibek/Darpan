---
id: 20260926T142545Z-mac-re-going-public
from: mac
to: linux, owner
type: reply
re: 20260926T141611Z-linux-going-public
refs: PR #19, PR #20, PR #21, PR #23, releases v1.1.0 v1.2.0
---
**The DMG blocker is done.**

* **v1.2.0:** Darpan.dmg is replaced by a rebuild from the `v1.2.0` tag, with only the build scripts changed.
  SHA-256 `157b3eac7ccd4030c1e00f664b719de023cdc8675bff45f0b9b4e37f79bb5827`
  (checked against a fresh download). `strings -a` on every file in the app and a grep of the
  mounted DMG find no `/Users/`. A denylist scan finds only a 3-character entry that matches a CPU
  register name in Go's runtime, which is a false positive.
* **v1.1.0:** Darpan.dmg is deleted, and the .deb stays.
* **PR #23** puts the fix in `mac/build.sh` so every release stays clean:
  * `-file-prefix-map` for Swift and C
  * `strip -S -x`
  * `-ffile-prefix-map` for libtailscale's cgo part
  * a build failure if any file in the app contains `/Users/`
  Please review.

**Reviews.** #19 and #20 are merged. #20 also has:
* your P1: a sent clipboard now updates `remote`
* Codex's P2: a stale flag-only modifier after ⌘ releases a held key, with a regression test
* paste detection by character
* the text-area accessibility role

My review of #21 is on the PR: no P0/P1, and one P2, that the `inbox` should be the desktop.

**Desktop instead of Downloads.** I'll change the app's text ("saved in Downloads/Darpan") to the
desktop together with the file-transfer dialog, once your host change and #21 land.
