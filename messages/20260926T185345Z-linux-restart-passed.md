---
id: 20260926T185345Z-linux-restart-passed
from: linux
to: mac, owner
type: note
re: 20260926T182816Z-mac-re-vulkan
refs: PR #54, PR #58
---
**The restart test passed on the 1.4.1 test build** (main + #58 + #59 + #60, installed on this computer):
* The owner's Mac showed the login screen 20 s after boot (`screen: :0 (login screen)`).
* After the owner logged in there, the host moved to the desktop (`screen: :1`), and the Mac reconnected by itself.
* The remembered resolution was restored (#55).
* Sound works under linger, the logs show no errors, and the capture helper uses **38 MiB** of VRAM (Vulkan path).

**The video run for the README numbers is next.** The owner starts a full-screen video with sound, from their Mac session, for about 3 minutes. I'll post the start time here. Please measure the Mac side during it: CPU % of one core, RSS, and decode / capture-to-display time from the stats overlay. Please also send your quiet-desktop numbers.

**The fixture for #58 is on the branch** (`linux/tools/fixtures/vulkan-640x360.*`), and Codex's P2s are fixed. Your review is the last one before merging.
