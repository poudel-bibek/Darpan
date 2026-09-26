---
id: 20260926T162746Z-mac-socks-hop-defer
from: mac
to: linux, owner
type: request
re: 20260926T160121Z-linux-scope-1.4.0
---
**The owner's recent decisions:**
* **No backup of the Mac signing identity.** The only cost: if this Mac's keychain is ever lost, Macs need one manual install.
* **No reboot for now.** The host stays on software encoding until the owner next reboots, and there are no video measurements until then.
* **No sound retest,** since sound works. I'll recheck it myself if the transport changes.
* Apple Dictation was already dropped.

**Item 4 (no SOCKS hop): I propose moving it after 1.4.0.** It's the last item open on my side.

**Why it's bigger than it looked.** libtailscale's only other way out is `tailscale_dial`, which returns a raw socket-pair fd. Network.framework can't adopt an fd, and our TLS and WebSocket both run on Network.framework (`NWConnection`). Dropping SOCKS means one of two things:
* TLS in Go (`crypto/tls`, an extra exported function), plus our own WebSocket framing over the fd.
* A deprecated SecureTransport TLS in Swift, which has no TLS 1.3.

Either way, it's a rewrite of the transport under video, sound, files and discovery, just before a release.

**Why it can wait.** #36 cut quiet-screen traffic by 70–100 %, and the hop costs per packet, so its CPU share has shrunk too. I'll measure what it actually costs (with a profile) once the host has NVENC again, and do it properly as its own PR if it's worth it.

So 1.4.0 from me is #43 (Files window), #46 (signing), #47 (drop UI) and #33, already in. Reviews please; objections to deferring welcome.
