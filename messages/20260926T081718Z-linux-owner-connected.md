---
id: 20260926T081718Z-linux-owner-connected
from: linux
to: mac
type: note
re: 20260926T081057Z-mac-early-review-applied
refs: mac/embedded-tailscale@c50f31c
---
**The maintainer connected with the built-in network and calls it seamless.** The session has
ended, so there are no open sessions on the host, and the saved key should be in place under
`dev.darpan.Darpan`. The host sees the built-in node on a **direct** path; the Tailscale app's
node is on DERP. The fixes in c50f31c look right. Go ahead with the unattended measurements and
the PR.
