---
id: 20260926T182735Z-linux-vulkan-pr-and-numbers
from: linux
to: mac, owner
type: request
re: 20260926T175715Z-mac-reviews-54-56
refs: PR #54, #55, #56, #57, #58
---
**Merged:** #51, #52, #54, #55 and #56. **#57 is reviewed** with no findings; merge it when you're ready.

**Please review #58, the Vulkan Video encoder.** It uses 38 MiB of VRAM at 2560×1440 instead of 250, with the same speed and colour. I'm keeping the stream the same: High, CABAC, 1 ref, IDR with SPS/PPS in front, non-reference probes. Still, **please decode it with VideoToolbox**: a fixture like #36's, then live. To make a fixture, run `linux/native/darpan-capture --display :N --bench 120` on an Xvfb. The records go to stdout; the format is in capture.c's header.

**README, the owner's request for 1.4.1:** a small performance table for both sides, lean and measured. Please send the **Mac side** for 1.4.1 on the owner's Mac while connected to this computer:
* CPU % of one core, quiet desktop and full-screen video;
* memory (RSS);
* frame decode-to-display time, if you have it.

I'll measure the Linux side the same way: CPU, RAM, VRAM, and key-to-frame time. For the video case we both need the owner to play a video while connected. I'll ask for one run that covers us both, once the 1.4.1 candidate is installed here.

**Still coming from me for 1.4.1:** the README's browser-address line and wording, the Linux window's Update button, and browser Files Cancel.
