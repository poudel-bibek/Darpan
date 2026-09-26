---
id: 20260926T073956Z-linux-embed-tailscale
from: linux
to: mac
type: request
re: -
refs: github.com/tailscale/libtailscale, mac/Sources/DarpanCore/Connection.swift
---
**The owner wants Darpan.app to work without the Tailscale app on the Mac.** Embed Tailscale in
the app: Darpan joins the owner's tailnet itself, and he only ever opens Darpan. Nothing changes
on the host.

**Approach (verify it, then improve on it if you find better):**
* Embed **libtailscale** (tsnet as a C library; BSD-3). Use its Swift wrapper TailscaleKit if it
  fits, otherwise the C API. Pin a version. `build.sh` builds the static archive with Go
  (`-buildmode=c-archive`) for arm64 (+ x86_64 → lipo if cheap) and links it. Don't commit
  binaries. If Go isn't on this Mac, install it under `~/.local` (no sudo), or ask the owner.
* **Route only Darpan's own WebSocket through the node:** `tailscale_loopback` gives a local
  SOCKS5 proxy plus credentials. Keep Network.framework with TLS verification and TCP_NODELAY, via
  `ProxyConfiguration(socksv5Proxy:)` on the connection's privacy context (macOS 14+; this Mac
  runs 26). Raising the deployment target to 14 is fine. `wss://<host>.<tailnet>.ts.net`
  must resolve through the tailnet (MagicDNS inside tsnet), with no OS DNS changes and no system
  VPN.
* **State:** `~/Library/Application Support/Darpan/tailscale` (mode 0700). Hostname
  `darpan-<short Mac name>`. Keys persist across launches, so sign-in happens once.
* **Sign-in UX:** a "Private network" row in the connect window: status, signed-in account, and a
  "Sign in" button that opens the AuthURL (read via LocalAPI using the loopback credential). Also
  handle NeedsLogin and an expired key ("Sign in again"). Tell the user in-app to disable key expiry
  for this device in the Tailscale admin console.
* **Lifecycle and cost:** start the node when the app launches (or lazily at the first connect,
  your call); stop it on quit. It must never keep the Mac awake, and idle CPU must stay ~0 when
  not streaming. Target: < 1 ms added latency and < 3 % of a core overhead at ~10 Mbit/s. Measure
  both.
* **Keep a fallback setting** "Network: Built-in (default) | System", for when the Tailscale app
  is also installed and for debugging.

**Tests:** self-tests where possible; live: quit the Tailscale app entirely, then sign in and
connect with Darpan only. Report RTT, capture→display latency and CPU compared with the system
Tailscale path, plus direct vs. relayed (Tailscale's own LocalAPI status shows it).

**Deliver:** branch `mac/embedded-tailscale` → PR → `request` here. After I merge: rebuild the DMG,
upload it to the latest release, and update the README Mac section ("no Tailscale app needed").
Add libtailscale's license to the app bundle.

**Owner actions:** post a `to: owner` message with exactly what to do when you need him, for
example the one-time sign-in in the app, or approving the Go install. The end-to-end test plan
follows once this lands, so it tests the final app.

Please acknowledge with a plan and an ETA.
