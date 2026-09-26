# Notes on the Mac client

Deviations from `MAC_PROMPT.md`, observations about the host and
protocol (nothing in `linux/` or `PROTOCOL.md` was changed), and what hasn't been tested yet.

## Host / protocol observations (all resolved in host 1.0.1)

* **Paste race:** fixed on the host. A `clip` is fully applied before any later message from that
  session is processed, so `clip` followed by Ctrl+V pastes the new text. The client keeps sending
  `clip` right before the key.
* **Cursor cache:** PROTOCOL.md §4 now says to cache cursor images by id for the whole session
  (the Mac client does).
* **`stats.win` / `stats.q`:** documented in PROTOCOL.md §3.4 (frames allowed in flight; smoothed
  queueing delay in ms). The client shows neither.
* Also in 1.0.1, with no client change needed: `modes.native` is the mode that *Native* restores,
  and a paused viewer's encoder stays down until the next `start`.
* The linux side accepted the deviations below.

## Deviations from MAC_PROMPT.md

* **Activity:** `ProcessInfo.beginActivity` uses `[.userInitiatedAllowingIdleSystemSleep,
  .latencyCritical]` rather than plain `.userInitiated`. A forgotten session shouldn't keep a
  laptop awake; the client reconnects after wake. It's held only while connected or reconnecting.
* **Keys pressed while ⌘ is held** go out as an immediate down+up pair (PROTOCOL.md §5, Mac
  guidance), so holding ⌘+key produces repeated taps rather than one long press. Keys pressed
  before ⌘ keep normal hold semantics and are released when ⌘ goes up.
* **Capture→display latency** is measured when the decoded frame is handed to the display layer.
  Window-server compositing (about one display refresh) isn't included.
* **Cursor size:** the remote cursor is scaled like the video (PROTOCOL.md §4), but it's never
  drawn smaller than 12 pt tall. Otherwise a 4K screen fit into a small window gives a pointer
  too small to use.
* **Keychain:** items live in the login keychain (generic password, service
  `dev.darpan.Darpan`, account = host origin, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
  The data-protection keychain needs a signing team and entitlements, which an ad-hoc build
  doesn't have. After a rebuild with a new signature macOS may ask once to allow access.
* **Extra:** a `mac/tools/FakeHost` target, and debug-only test hooks (`DARPAN_DEBUG_CMDS`,
  `DARPAN_DEBUG_SOCKS`; not in release builds).
* **Deployment target** raised to macOS 14, for `ProxyConfiguration` on the connection's privacy context.

## Built-in network (libtailscale)

* libtailscale is pinned at commit `59d4bb8` (tailscale.com v1.94.1), built by
  `tailscale/build-libtailscale.sh`. It's a universal c-archive with log upload compiled out
  (`envknob.SetNoLogsNoSupport`, `logtail.Disable`) and `GOMAXPROCS` capped at 2.
* Only Darpan's WebSocket goes through the node's loopback SOCKS5 proxy. TLS still ends in the
  app, with system certificate validation. `allowFailover = false`, so it never falls back to a
  direct connection. The host name is handed to the proxy unresolved, so MagicDNS names resolve
  inside the node. No system VPN, no DNS changes.
* One node per state directory: an exclusive `flock` on `darpan.lock`. A second copy of the app
  would otherwise run the same node key and stall the first one's session.
* The node starts at launch once signed in, or when the connect window shows in Built-in mode,
  and closes on quit. Its status is polled once a second, only while the connect window is visible.

## Measured

Apple M1, macOS 26, against the Linux host (2560×1440 NVENC, direct path both ways). Static
desktop at about 57 fps and 0.1–0.2 Mbit/s; medians over 3 min after a 60 s warm-up:

| | Built-in | This Mac's (Tailscale app) |
|---|---|---|
| RTT | 31 ms | 30–32 ms |
| capture → display | 26–27 ms | 25 ms |
| decode (hardware) | 4.3–4.5 ms | 3.9 ms |
| CPU, Darpan | 17–19 % | 11–12 % (+ ~2 % in the Tailscale extension) |

Latency with the built-in node matches the system path. **CPU overhead is an open item:** about
5 % of a core even at this light load. It's spread over the Go runtime's threads, and
`GOMAXPROCS=2` only brought it from 18.6 % to 17.1 %. It's being profiled in a follow-up.
Idle (connected, window hidden): the stream stops and CPU is about 0.3 %.

Against FakeHost on the same Mac (1920×1080 at 60 fps, release build): hardware decode 2.2–2.5 ms,
capture→display 17 ms (about 12 ms of it is FakeHost's own encode), 5–6 % CPU.

## Tested live against the Linux host

* Sign-in with the built-in network: first sign-in, saved key, relaunch with saved node state,
  wrong password.
* Video, keyboard and mouse in a real session; the session stops when hidden.
* Checked in full against FakeHost only:
  * kick, restart, drop, stall recovery
  * clipboard both ways
  * uploads
  * resolution change and revert
  * IME text
* Not yet run live: the controlled ~10 Mbit/s load test, file drop to `~/Downloads/Darpan/`, and
  resolution change on real xrandr modes.
