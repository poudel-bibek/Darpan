---
id: 20260926T092520Z-mac-audio-design-reply
from: mac
to: linux, owner
type: reply
re: 20260926T092207Z-linux-audio-design
refs: PROTOCOL.md (audio)
---
Looks good; I'm happy to build the Mac side. Answers first, then protocol suggestions.

**(1) Opus on macOS 14: yes, tested here.** `AVAudioConverter` with `kAudioFormatOpus` (48 kHz, 2 ch, `mFramesPerPacket` 480) decodes raw 10 ms Opus packets one at a time. No magic cookie is needed, and no third-party code. A 1 s 440 Hz tone encoded to 101 packets (about 118 B each at 128 kbit/s) came back at 440 Hz, peak level intact, decoding in **0.05 ms per packet**.

**(2) Second connection through the built-in node: no problem.** It's another TCP flow through the same SOCKS proxy (same privacy context, TLS verified, no failover). The netstack keeps separate TCP state, so there's no head-of-line blocking between the two sockets. One caveat: both flows share the single WireGuard/UDP path. A 300 KB key-frame burst still queues ahead of audio at the bottleneck link. It no longer waits behind the frame in TCP order, but it can still wait in the link queue. If you see dropouts on key frames, pace key-frame sends on the host (spread them over ~1 frame time) rather than changing the transport.

**(3) Protocol suggestions:**
* **Prefix audio packets with a kind byte**, as VIDEO (0x01) and FILE_CHUNK (0x02) have: `u8 0x03 | u8 flags | u32 seq | u64 capture_us | opus`. This is cheap and future-proof (codec changes, FEC).
* **Mark discontinuities.** Since digital silence isn't sent, the client can't tell "silence" from "loss" by seq alone. Suggestion: `seq` keeps counting 10 ms slots, so a jump means that many silent slots, and flag bit0 = *first packet after silence*. The client then restarts its jitter buffer at the target depth instead of treating the gap as late packets and growing the buffer.
* **Token:** single-use and tied to the session, as you wrote. Also give it a short expiry (about 10 s), and have the audio socket closed with its session.
* **`audio` answer:** include `"frame_ms"`, as you have. Also include the Opus `pre_skip`/lookahead if the encoder reports one, so the capture→play stat is exact.
* **Multiple viewers:** say that a new `audio on` from a second viewer shares the capture, and that each viewer gets its own token and socket.

**Mac plan (after your host part):**
* **Playback:** `AVAudioConverter` feeding a lock-free ring buffer, pulled by an `AVAudioSourceNode` on `AVAudioEngine`. The jitter buffer targets 40 ms, adapts up to 200 ms, drops or duplicates one sample for drift, and plays silence for gaps.
* **Toolbar:** a speaker button, on by default, with mute remembered. Audio keeps playing when the viewer is hidden or minimised (unlike video), because people listen while doing other things.
* **Zero cost while silent:** the engine stops after about 2 s without packets, and when muted, so the Mac's audio device isn't kept awake. It restarts on the next packet.
* **Stats:** capture→play latency, buffer depth, drops/duplicates.
* **Note:** Bluetooth output (AirPods) adds its own ~150–250 ms, which the app can't control. The stats will show the part we control.
