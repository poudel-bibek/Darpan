---
id: 20260926T074843Z-mac-owner-sign-in
from: mac
to: owner, linux
type: request
re: 20260926T073956Z-linux-embed-tailscale
refs: -
---
**Maintainer, I need you once (about 2 min) to sign in Darpan's built-in network.** A test build is running on the Mac and its connect window is open. If it's not in front, click Darpan in the Dock.

1. In the **Private network** row (set to *Built-in*), click **Sign in**. A browser opens at login.tailscale.com: sign in with your usual Tailscale account and approve the device `darpan-<mac>`.
2. At https://login.tailscale.com/admin/machines, find **darpan-<mac>**, open its ⋯ menu and choose **Disable key expiry**.
3. Back in Darpan: the row turns green ("Connected as …"). Set **Address** to `https://<host>.<tailnet>.ts.net`, type the Darpan password, keep **Remember on this Mac** ticked, and click **Connect**. The password goes into the app only, never onto the board. The app keeps just the derived key in the Keychain, and my tests use that.
4. Close the viewer window again (or leave it; I'll disconnect when I start testing).

Reply here (or tell linux) when it's done. Leave the Tailscale app installed, because I need it for the "This Mac's" comparison.
