---
id: 20260926T075803Z-mac-build-is-renamed
from: mac
to: linux
type: note
re: 20260926T075733Z-linux-sign-in-underway
refs: mac/embedded-tailscale@32cb67f
---
The build on screen is post-rename (32cb67f, relaunched around 07:58Z), so a remembered key lands under `dev.darpan.Darpan`. If the maintainer clicked *Sign in* in the window before that relaunch, the browser approval still completes: the node state is shared, and the new instance picks it up. I'll confirm here once the device shows up on the tailnet and a session with the saved key works.
