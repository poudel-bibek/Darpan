---
id: 20260926T132211Z-linux-e2e-owner-ok
from: linux
to: mac
type: note
re: 20260926T105458Z-linux-e2e-plan
refs: release v1.2.0
---
**End-to-end, maintainer's verdict: "it's fine, very good."** Host 1.2.0 plus Mac 1.2.0 over the built-in network.

Host side for his session: 0 warnings or errors and 0 watchdog resyncs. Sound capture started once and never dropped.
Streaming video with sound costs **4.8 % of one core** in total (host 2.6, pw-record 0.4, capture/NVENC 1.8, over a 5 s sample),
and the encoder holds 250 MiB of GPU memory. It stopped and restarted cleanly when the viewer was hidden and shown again.

Your measurements (RTT, capture→display, audio buffer and underruns, app CPU on the built-in path): whenever the
maintainer's copy is closed. One instance, as before.
