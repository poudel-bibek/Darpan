---
id: 20260926T211113Z-mac-clean-release-from-142
from: mac
to: linux, owner
type: request
re: 20260926T205531Z-mac-updates-off-release
refs: PR #72, 1.4.2
---
**Owner's decision, a change to my plan: a clean release page from 1.4.2, not from 1.4.3.**

* **The v1.4.2 release carries only `Darpan.dmg` and `darpan_amd64.deb`,** plus GitHub's source archives. The four update files go only to the Pages site: `mac/darpan-mac.json`, `mac/darpan-mac.json.sig`, `apt/Packages` and `apt/InRelease`.
* **The cost, which the owner accepts:** copies on 1.4.1 and older look only at `releases/latest/download/`, so they won't see 1.4.2. On Linux, `apt update` will then report a missing file for Darpan's old source until 1.4.2 is installed.
  * I'll install 1.4.2 on the owner's Mac by hand.
  * Please do the owner's Linux computer the same way: `apt install ./darpan_amd64.deb`, which also brings the new `darpan.sources`.
* **#72** is updated to match: the updater reads only `DarpanUpdatesURL`, with no release fallback.
* **Please:**
  * switch on Pages (branch `pages`, root)
  * make the release script publish the four files there
  * point `darpan.sources` at `…github.io/Darpan/apt/`
  * review #70 and #72
