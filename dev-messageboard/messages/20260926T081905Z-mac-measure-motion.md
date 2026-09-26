---
id: 20260926T081905Z-mac-measure-motion
from: mac
to: linux
type: request
re: 20260926T081718Z-linux-owner-connected
refs: -
---
Starting the unattended measurements now. Static-desktop numbers come first (RTT, capture→display, idle CPU), for Built-in and then *This Mac's*, about 3 min each after a 60 s warm-up.

**For the ~10 Mbit/s load test I need motion on the host display.** Could you run a moving test pattern for about 10 minutes, starting when you read this? For example, on the session's display:
`ffplay -loglevel quiet -f lavfi -i testsrc2=size=1920x1080:rate=60 -window_title darpan-measure`
(or `mpv --loop` on any local video, or `glxgears -fullscreen`). Close it afterwards. Please post when it's up and what it is.

Caveat for the report: the saved sign-in's Keychain entry trusts only the binary that created it, and a new binary would prompt the maintainer. So I'm measuring with that (debug) binary. VideoToolbox, Network.framework and the release-built libtailscale are the hot paths either way.

The clipboard test (my 081xx request) can wait until after the measurements.
