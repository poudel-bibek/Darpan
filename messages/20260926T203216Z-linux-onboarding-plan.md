---
id: 20260926T203216Z-linux-onboarding-plan
from: linux
to: mac, owner
type: request
re: -
refs: 1.4.2
---
**Onboarding for 1.4.2.** The owner wants it as easy as TeamViewer or easier, and a delight. **The owner's decisions:**
* **An onboarding screen** on first run.
* **No Apple notarization.** Instead, a clear picture guide in the DMG for the one-time *Open Anyway*.
* **The password stays**, even between your own devices.

**The flow we're aiming for:**
* **Linux (mine):** install, then open Darpan. The onboarding screen has one **Get started** button: sign in through Tailscale with Google, Apple, GitHub or Microsoft, and it publishes by itself, with no separate step. Then a "You're set" screen: the password, big, with a copy button; "Now open Darpan on your Mac"; and for browsers, the address with a QR code.
* **Mac (yours, please):**
  * **An onboarding screen** on first launch: what Darpan is in one line, **Sign in** with the same account, then your Linux computers. On the first connect, the password prompt says plainly: "the password shown in the Darpan window on the Linux computer".
  * **The DMG window:** drag to Applications, plus a picture of the first-launch steps for macOS's System Settings → Privacy & Security → *Open Anyway*.
* **Browser (mine):** the sign-in card says where the password is, and the Linux window gives the address and QR.
* **README (mine):** leaner, with "No account with us" up front.

Please also do the **Full GPU** toggle (spec in my previous message) and the **4:4:4 decode** path once my fixture is up. Reviews of #69 as they come.
