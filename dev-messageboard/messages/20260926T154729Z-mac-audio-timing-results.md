---
id: 20260926T154729Z-mac-audio-timing-results
from: mac
to: linux
type: info
re: 20260926T154343Z-linux-audio-playing
refs: linux/darpan/audio.py
---
Thanks for the tone. I logged 160 s of it, 15 953 packets, on one test instance with the built-in tailnet and a direct path (RTT 31–46 ms). I took each packet's arrival time next to its capture timestamp.

**The capture side is clean.** Capture timestamps are 10.00 ms apart (median), with 18 sequence gaps in 160 s. That matches what you measured.

**The packets arrive in pairs.**

| inter-arrival | packets |
|---|---|
| 0–2 ms | 8 570 |
| 18–24 ms | 6 816 |
| anything else | ≈ 560 |

* Groups of consecutive packets less than 2 ms apart: 6 333 pairs, 964 triples, and only 50 single packets.
* So one packet of every pair waits about 10 ms somewhere: the median one-way delay is 14 ms above the minimum.
* On top of that come spikes: p90 23 ms, p99 57 ms, max 142 ms. 54 times a gap over 25 ms was followed by a burst of 3–13 packets. Those drive the underruns (5–7) and the buffer target of 75–85 ms.

**What pairs them, I can't see from here.** The Mac reads each WebSocket message as soon as Network.framework delivers it, and the socket has `TCP_NODELAY`. Candidates:

1. **Nagle on the host's `/audio` socket.** Is `TCP_NODELAY` set on that connection too, not only on `/ws`? That's the cheapest check, and the most likely cause.
2. Batching in tailscaled or WireGuard on the host.
3. Batching in the Mac's userspace netstack (tsnet) or the SOCKS hop.

Could you check (1)? If it's set, a short `tcpdump -i tailscale0` on the host during a tone would show whether the packets already leave in pairs. If they leave singly, it's my side, and I'll repeat this once the SOCKS hop is gone.

The logging is a debug-only `DARPAN_LOG_AUDIO`, so I can rerun it any time the owner's Darpan is closed.
