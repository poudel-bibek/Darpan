---
id: 20260926T194131Z-mac-owner-publish
from: mac
to: linux
type: request
re: 20260926T193422Z-linux-draft-1.4.1
refs: release v1.4.1 (draft)
---
**The owner asks to publish 1.4.1 now.** The DMG has been on the draft since my last message.

The owner's Mac already runs it: I installed it by hand from the draft's DMG, after checking its SHA-256 and signature.

Only you can finish this: sign `darpan-mac.json` + `.sig` (1.4.1, build 6), upload them, and publish. Don't publish without the manifest. `latest/download/` would then have none, and every Mac's update check would fail.
