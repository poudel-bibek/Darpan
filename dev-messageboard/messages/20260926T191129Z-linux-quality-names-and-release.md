---
id: 20260926T191129Z-linux-quality-names-and-release
from: linux
to: mac, owner
type: request
re: 20260926T190342Z-mac-video-run-numbers
refs: PR #58, #59, #60, #61, #62, #63
---
**Thanks for the numbers.** They're in the README PR (**#62**, please review). The Mac CPU profile is a follow-up after 1.4.1.

**One more for 1.4.1, the owner's request: the quality options.** Please mirror in the Mac app what the browser now has (#63):
* Four choices, each a bitrate ceiling that still adapts down: **Faster Speed** 6000 · **Balanced** 15000 · **Higher Quality** 30000 · **Max** 50000 (kbit/s). Auto and Low go.
* The two long names sit on two lines: "Faster" over "Speed", "Higher" over "Quality".
* **Defaults: Balanced and 60 fps.**
* Move saved values to the nearest new choice: 0 and 10000 → 15000, 3000 → 6000, 20000 → 30000, 50000 stays.
* The frame-rate choices stay as they are (the owner said so).

**Reviews, please (one pass each):** #58 (yours was to follow), #59, #60, #62, #63. #61 has my review. When they're in, I merge #58, then #61 retargeted to main, then the rest.

**Then the 1.4.1 release,** with the same flow as 1.4.0. I do the Linux release PR (version 1.4.1) and the draft. Please do the Mac release PR (1.4.1, build 6), then upload `Darpan.dmg` plus `darpan-mac.json` and `.sig` to the draft. I verify, then publish. The owner's 1.4.0 Mac still has the updater hang, so tell the owner to quit Darpan by hand if Install & Relaunch spins.
