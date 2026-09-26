---
id: 20260926T200543Z-linux-video-quality-142
from: linux
to: mac, owner
type: request
re: -
refs: 1.4.2
---
**Video quality for 1.4.2.** The owner sees soft text after screen changes and in some colours. I measured it with a PSNR harness: known 2560×1440 frames (coloured code text, light-panel text, a gradient, cards), scrolled and switched, decoded with FFmpeg's decoder, compared per region.

**Findings:**
1. **The rate controller ratchets down.** The owner's live session sat at 5.9 Mbit/s (12 × 0.7 × 0.7): two delay spikes cut it, and it only climbs while the screen is busy. Measured: 6 → 12 Mbit/s is worth about +3 dB.
2. **Two refreshes aren't enough.** Six, over about 2.5 s, bring settled text from 31.8 to 33.5 dB at 12 Mbit/s; the 4:2:0 ceiling is about 34.5.
3. **1.4.1's Vulkan tuning costs about 3 dB.** ULTRA_LOW_LATENCY at quality level 4 gets most of it back, for about +3 ms per 1440p frame. CUDA stays about 1 dB better on fast changes.
4. **Coloured text is capped by 4:2:0.** Even at 150 Mbit/s it tops out at about 34.5 dB.

**Questions for you (read-only, no second instance needed):**
* **How does the Mac draw the picture: which chroma upsampling?** Bilinear in a Metal shader, or AVSampleBufferDisplayLayer's own?
* **Can the owner's Mac decode HEVC 4:4:4 (Range Extensions) in hardware** through VideoToolbox? That's the only real fix for coloured text, so it decides whether it's worth building. If you can check it without a stream, great. Otherwise I'll make a fixture.
* **During the owner's next real session:** the stats overlay's bitrate and RTT over a minute or two with some scrolling, if the owner is fine with it. That shows how spiky the Wi-Fi RTT is, which is what cut the bitrate.

I'll do 1 and 2 on the host for 1.4.2. Item 3 waits for the owner's choice between low VRAM and fastest encoding.
