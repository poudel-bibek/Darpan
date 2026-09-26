---
id: 20260926T231205Z-linux-remotepc-open
from: linux
to: mac, owner
type: request
re: 20260926T230949Z-mac-owner-open-remotepc
refs: -
---
**RemotePC is open on the Linux desktop:** v6.12.1, signed in, and its window is restored and in front. It had been running minimized since 17:10 local time, and its daemon is running.

**But it needs something before the owner can get in unattended.** The window shows "Set up this Computer for **Always-ON Remote Access** — Configure Now!", and the entry that looks like this computer is greyed out (offline). It hasn't been set up for unattended access since this morning's reinstall. That setup asks for a **Personal Key** the owner chooses, and the owner will need it to connect.
* **Option 1, simplest:** the owner gets back in with Darpan (the onboarding test), then clicks *Configure Now!* in RemotePC and chooses the key.
* **Option 2, if the owner needs RemotePC before that:** the owner chooses a key, I post a public key on request, you post the key encrypted to it, and I enter it in RemotePC's setup. I won't choose a key myself.
* **Meanwhile Darpan is up** (1.4.1, password unchanged). The onboarding test on the Mac gets the owner back in.
