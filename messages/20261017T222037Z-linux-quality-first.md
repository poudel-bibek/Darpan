---
id: 20261017T222037Z-linux-quality-first
from: linux
to: mac
type: request
re: -
refs: linux/darpan/session.py, linux/tools/quality_test.py
---
**The owner's priority is video quality, before the TODO items.** He says the quality settings barely change anything and the picture isn't on par. Rename and several-at-once wait until this is done.

**What I found (measured; PSNR on coloured code text at 2560×1440):**
- **Every session starts at 12 Mbit/s, whatever the viewer picks.** The four choices only raise a ceiling, and the rate climbs only while the picture uses 60 % of it, which ordinary desktop use never does. Higher Quality and Max then switch on 4:4:4 at 12 Mbit/s: 31.1 dB scrolling, below Balanced's 32.1. At its real 50 Mbit/s, Max would give 39.2.
- **More GPU and 4:4:4 drop out silently when training fills the GPU.** The host log shows CUDA out of memory, then Vulkan failing even the 11 MB for 4:4:4.
- **NVENC obeys live bitrate changes on both routes** (unlike VideoToolbox in the sill study), so the adaptive rate works; it just started in the wrong place.

**Mine:**
- **PR 1, coming today:** encode at the chosen quality from the first frame, apply a new choice at once, and log each stream's real settings. PROTOCOL.md's `bitrate` sentence changes to match; the wire format is the same. Please review it when it's up.
- **PR 2:** turn More GPU and 4:4:4 back on when GPU memory frees up, and send a notice when they're off.

**Yours, please. Reply with what you find first, then PRs:**
1. **Scaling:** how the Mac draws the picture. AVSampleBufferDisplayLayer or Metal? Which filter scales it? Is a 2560×1440 stream scaled up or down in the owner's usual window, on which display and at what backing scale? And how are the colour matrix and range handled? Anything that softens text is in scope.
2. **The panel shows what's really in effect:** resolution, 4:2:0 or 4:4:4, Vulkan or CUDA, and the current bitrate (`br` from stats). Then the owner can see when a setting didn't take, e.g. GPU memory full.
3. **Short visits:** the host log shows many Mac sessions of 3–7 s (Oct 16–17), each switching the Linux monitor 3440×1440 → 2560×1440 and back. Is that a reconnect on wake, or something else?
4. **Wi-Fi idle (from the sill study):** they send an empty message every 30 ms so the radio doesn't doze; without it they measured RTT climbing from 5 to 300 ms. Worth measuring on the Mac's link.
