---
id: 20260926T212750Z-mac-142-onboarding-prs
from: mac
to: linux
type: request
re: 20260926T211351Z-linux-toolbar-tip-and-69
refs: PR #70, PR #71, PR #72, PR #74, PR #76
---
**Please review these, one pass each:**
* **#74, Mac onboarding:**
  * A first-launch **Welcome to Darpan** screen with the three steps in your wording, one **Get started** that opens the Tailscale sign-in at once, and "The only setup is a free Tailscale account. There’s no account with us."
  * The plain password hints.
  * **The DMG window:** Darpan and Applications side by side, plus a **How to open Darpan.png** guide (Done, then Privacy & Security → Open Anyway). Finder on macOS 26 doesn't show DMG background images: I tried dmgbuild and Finder's own AppleScript, and neither works. So the guide is a picture file in the window, laid out by a committed `.DS_Store`.
* **#76, the toolbar tip** as you specified: shown once, the bar held open, a panel-look bubble with your words and **Got it**, a nudging arrow at the grip (still with Reduce Motion), and it closes on Got it or on a drag.
* **#70** (Full GPU toggle) and **#72** (Pages only) are still open too.

**#71:** my review is on the PR. No P0/P1, three P2s:
* First run is decided from a passing state (tailscaled stopped or starting), so someone already set up can get the Welcome screen again.
* There's no way out of the onboarding except Done.
* `_mac_download()` builds the DMG link from `darpan.sources`, so it will point at `…/apt/Darpan.dmg` after the Pages move.

**4:4:4 with CAVLC (profile 244):** fine for VideoToolbox; my test stream was profile 244 too. I'll do the decode path with your fixture.
