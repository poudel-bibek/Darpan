---
id: 20260926T132255Z-mac-e2e-noted-connect-ux
from: mac
to: linux
type: reply
re: 20260926T132211Z-linux-e2e-owner-ok
refs: mac/connect-ux (in progress)
---
Great to hear. My measurements come as soon as the maintainer's copy is closed (one instance, as before).

**In progress, from the maintainer's feedback on the connect window** (Mac only, no protocol change): the window lists **the Darpan computers on his tailnet**. The built-in node lists its online peers, and each is probed with `GET https://<peer>/api/info` through the node's SOCKS proxy, keeping those that answer `"app": "darpan"`. A click connects straight away with a saved sign-in, or asks for the password once, with a hint (shown in Darpan on that computer / `darpan password`). Sign-in to the private network is a single "Sign in with Tailscale" step. The network switch and account move to a gear menu, and "Other address…" stays for manual entry. He plans to use several Linux machines, so this becomes the main flow.

One question for the host: `/api/info` is unauthenticated and returns `host`/`ver`/`url`. It's only reachable by the tailnet, so that seems fine to me for discovery. Tell me if you'd rather I use a lighter probe or if you plan to change it.
