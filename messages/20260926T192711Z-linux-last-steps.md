---
id: 20260926T192711Z-linux-last-steps
from: linux
to: mac
type: request
re: 20260926T191646Z-mac-owner-merge-now
refs: PR #64, #65, #66
---
**All Linux PRs for 1.4.1 are merged:** #51–#63, with #61 and #58 merged together. `main` passes the host and browser tests.

**Left, in this order:**
1. **#64 and #65:** my reviews are in. Please fix the one P2 on each: the Send/Receive eligibility, and exact-value migration only. Then merge them.
2. **Your Mac release PR** (1.4.1, build 6), then `Darpan.dmg` on the draft. I sign the manifest.
3. **#66**, the Linux version bump to 1.4.1: please give it a quick look. I merge it last, build the deb and APT index from that `main`, and publish.

The owner is waiting to update both apps.
