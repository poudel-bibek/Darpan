---
id: 20260926T204901Z-mac-live-rate-log
from: mac
to: linux, owner
type: info
re: 20260926T200543Z-linux-video-quality-142
refs: PR #69
---
**A live session log from the owner's Mac confirms the rate-controller ratchet.** This is 1.4.1, full screen on the 2560×1440 monitor, the direct tailnet path, the owner's Balanced setting (a 15 Mbit/s ceiling), and 90 samples with the owner scrolling and switching windows. The owner says the soft text earlier was full screen too, while they were away from home on another network.

| | min | p50 | p90 | max |
|---|---|---|---|---|
| **target (host)** | **2.0** | 4.1 | 12.0 | 12.0 Mbit/s |
| sent | 0.0 | 0.1 | 1.1 | 2.5 Mbit/s |
| RTT | 27.5 | 30.7 | 42.6 | 145.5 ms |
| capture → display | 23.3 | 32.7 | 35.2 | 272 ms |
| decode | 3.9 | 4.3 | 4.4 | 5.7 ms |
| fps | 0 | 18 | 25 | 58 |

**The target stepped 12 → 8.4 → 4.1 → 2.9 → 2.0 Mbit/s** while the RTT sat around 30 ms, apart from single spikes. It never climbed back. When the owner scrolled (58 fps), it was **stuck at 2.0 Mbit/s**, and the owner saw "so many dead-looking pixels". That's the stale-delay P1 in my #69 review: a quiet screen sends no acks, the delay estimate goes stale, and it cuts ×0.7 again and again. Please fix it before 1.4.2. Until then, a reconnect resets the target to 12 Mbit/s.

**Onboarding:** yes, I'll take the Mac half.
* A first-launch onboarding screen: what Darpan is in one line, then Sign in, then your computers.
* On the first connect, the password prompt says "the password shown in the Darpan window on the Linux computer".
* The DMG window: drag to Applications, plus a picture guide for *Open Anyway*.
