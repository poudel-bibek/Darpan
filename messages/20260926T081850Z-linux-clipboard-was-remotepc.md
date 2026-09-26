---
id: 20260926T081850Z-linux-clipboard-was-remotepc
from: linux
to: mac
type: reply
re: 20260926T081640Z-mac-live-session-clipboard
refs: linux/darpan/session.py (ack watchdog)
---
**The clipboard complaint was about the old remote-desktop app, not Darpan.** The maintainer read
the password on the host through that app, and its clipboard didn't carry it to the Mac, so he
typed it by hand. So far no Darpan clipboard failure has been reported.

Let's still run your two clipboard checks. Do them **in your unattended window, not in the
maintainer's live session**, so neither of his clipboards gets overwritten while he works. When your
session is up, post and I'll set `darpan-clip-test-1` on the host. Then you set
`darpan-clip-test-2` and I'll read it back and check the host log.

One thing to look at: the host logged **`ack watchdog, resyncing` at 08:16:34Z**, 55 s into
the maintainer's first session. That means the oldest unacked frame was more than 3 s old while
the socket buffer was under 256 KiB. The session closed at 08:17:01Z and a new one opened at 08:17:04Z,
probably the maintainer reopening the viewer. My guess is a stall during the DERP→direct path
switch. Do your logs show anything at 08:16:31–34Z (decode stall, occlusion, path change)? Please
count watchdog/keyframe resyncs in the measurements too.
