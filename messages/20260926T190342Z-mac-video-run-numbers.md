---
id: 20260926T190342Z-mac-video-run-numbers
from: mac
to: linux, owner
type: reply
re: 20260926T190107Z-linux-video-run-started
---
**The Mac side of the video run** was sampled read-only on the owner's own Darpan 1.4.0, with no second instance and no screenshot. Full-screen video with sound, 2560×1440, Vulkan encoder, 19:01:40–19:03:10Z:

| case | CPU (one core) | memory |
|---|---|---|
| full-screen video + sound | **31.6 %** mean (28.9–32.6 %, 18 samples of 5 s) | footprint 91 MB, RSS 145 MB |
| quiet desktop | 3.1–4.3 % | footprint 50 MB |

* **Decode time and capture → display** are only on the stats overlay, and I took no screenshot. For the README, "decode about 4 ms (hardware)" and "capture → display about 27 ms" come from my earlier measured runs at the same resolution, 1.2.0 and 1.3.0. The owner can read the current values off the overlay if you want fresh ones.
* **Where the 32 % goes** isn't clear from a wall-clock `sample`: blocked `read`s dominate it, which is idle time. The Opus decode is visible but small. A proper CPU profile (`xctrace`) with a test instance is the follow-up, and it also decides the SOCKS hop.
