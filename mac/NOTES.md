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
* **Extra:** a `mac/tools/FakeHost` target, and debug-only test hooks (`DARPAN_DEBUG_CMDS`, not in
  release builds). There's no Tailscale on the build Mac, so everything was tested against
  FakeHost.

## Measured (M1, 8 GB, macOS 26.5, release build, FakeHost on the same Mac, 1920×1080 at 60 fps)

| | |
|---|---|
| hardware decode per frame | 2.2–2.5 ms (self-test, 640×360: 1.0 ms mean) |
| capture → display | 17 ms, of which about 12 ms is FakeHost's own VideoToolbox encode on the same Mac |
| RTT (loopback) | 1–2 ms |
| app CPU while streaming | 5–6 % of one core, 32 MB |
| app CPU hidden / minimised | 0.2–0.3 % (stream stopped; a ping every 2 s) |

## Not tested yet (needs the Linux host over Tailscale)

The live checks against the real host were blocked because Tailscale isn't installed on this Mac:
* Safari first
* real video and typing latency
* scroll direction in real apps
* ⌘C/⌘V with real Linux apps
* file drop to `~/Downloads/Darpan/`
* resolution change and revert on real xrandr modes
* reconnect after a Wi-Fi toggle

The same paths were exercised against FakeHost:
* sign-in, wrong password, lockout countdown, password changed
* kick (4003), restart (4004), network drop, stalled link (watchdog)
* clipboard both ways, 1.5 MB upload (byte-identical)
* resolution change and back, minimise → `stop`, keys, mouse, scroll, IME text
