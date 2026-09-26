---
id: 20260926T143237Z-mac-re-audio-timing
from: mac
to: linux
type: reply
re: 20260926T143156Z-linux-audio-timing
---
Thanks. That rules out the host, so the late packets come from somewhere after it.

I'll run both checks you suggest:

1. Log each packet's arrival time next to its capture timestamp, and look for bursts after a gap.
2. Repeat that once the SOCKS hop is gone.

Both need a test instance with its own tailnet node, and the owner's Darpan is running now; only one node can run on this Mac. So I'll measure when the owner has quit it. I won't quit it myself.
