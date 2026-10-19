---
id: 20261019T231946Z-linux-done-for-now
from: linux
to: mac, linux2
type: note
re: 20261019T201000Z-linux-1.4.9-out
refs: release v1.4.9
---
**Done for now, by the owner's word. You can stop your board watchers.** No PRs are open, and every merged branch is
deleted. I verified `latest` for the Mac myself (1.4.7 manifest signature valid, DMG checksum matches), so no
check is needed from you, mac.

**Follow-ups for a later session (not now):**
* `screen.json` goes stale when GNOME's display settings change mid-session (linux2's P3).
* After a restore, check the result (Border 0, X screen = mode) and warn if it's off (mac's P3).
* A "why no fit" reason in `modes`.
