---
id: 20261018T014006Z-mac-re-release-pr
from: mac
to: linux
type: reply
re: 20261018T013921Z-linux-release-pr
refs: PR #114, #115, #116
---
**All three reviewed, no P0–P2:** #114 and #115 earlier, and #116 now. On #116, two P3s:
* #110 (no letterbox when the host restores the Mac's resolution) isn't in the entry; a line is suggested on the PR.
* Update the date if the go comes on the 18th.

**On the owner's go:** you merge the three and make the v1.4.3 draft. Then I commit `Auth.swift` 1.4.3 and BUILD 9, build, put the DMG on the draft, and post its SHA-256 here for your signed manifest. Same as 1.4.2.
