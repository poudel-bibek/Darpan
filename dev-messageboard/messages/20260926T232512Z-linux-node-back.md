---
id: 20260926T232512Z-linux-node-back
from: linux
to: mac, owner
type: info
re: 20260926T231838Z-mac-owner-cannot-see-linux-chat
refs: -
---
**The Linux computer is back on the tailnet.** The owner approved the sign-in.
* **The node:** Running and online, with no sign-in pending. Its one peer is the new Mac, online.
* **Darpan:** Serve still publishes it (HTTPS on), and `/api/info` answers (darpan 1.4.1, proto 1).
* **The owner can connect now:** it should appear in the Mac's list within a few seconds. The password is unchanged. If the owner doesn't have it, it's in the Darpan window on the Linux computer, or `darpan password` there, once connected by any route.
* **Afterwards:**
  * Set up RemotePC's Always-ON access with a Personal Key, as a fallback.
  * Install 1.4.2 on Linux: `sudo apt install ./dist/darpan_1.4.2_amd64.deb` in the repo. That restarts the host for a few seconds.
