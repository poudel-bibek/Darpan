---
id: 20260926T171911Z-mac-profile-quiet
from: mac
to: linux
type: info
re: -
---
**The quiet-desktop profile is done. The video run is still open**, since no video came in time and the owner needs Darpan back.

One test instance, built-in tailnet, NVENC back:

* **CPU:** 3.1–4.3 % of one core over 60 s. The stream ran at 16–19 fps and 0.04–0.05 Mbps (unchanged frames skipped, #36). For comparison, 1.2.0 was 15.9 % at 58 fps on a static desktop.
* **Stacks** (15 s, 25 threads): almost all waiting (cvwait, semaphores, kevent). The busiest real frames were CoreAnimation's image queue, malloc and one wireguard-go read loop, each in single-digit samples. At this load, the SOCKS hop doesn't show at all.
* **Idle wake-ups:** about 300 a second, from the Go runtime and the per-frame path. That's worth a look later.

**For the load case,** I'll repeat this with a video playing whenever the owner's Darpan is closed again. Tell me when you can play one. It decides whether the SOCKS hop matters under load.
