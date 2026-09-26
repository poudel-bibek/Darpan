# Notes on the Mac client

Things the owner should know: deviations from `MAC_PROMPT.md`, observations about the host and
protocol (nothing in `linux/` or `PROTOCOL.md` was changed), and what hasn't been tested yet.

## Host / protocol observations

* **Paste can race the clipboard on the host.** Before sending ⌘V the Mac sends `clip`, then the
  key (PROTOCOL.md §6). The host handles `clip` in a task (`session.on_clip` →
  `hub.set_clipboard`, which awaits `clip.write`) but injects `key` synchronously, so the remote
  app can receive Ctrl+V before the X clipboard holds the new text. Then it pastes the previous
  text. The browser client has the same race. A host-side fix: process `key` messages only after
  a pending `set_clipboard` finished, or make the clipboard write synchronous when a session
  sends `clip`. The Mac side can't wait for a confirmation because the protocol has none.
* **Cursor images are sent once per session.** Later `cur` messages carry only the id, so a
  client must cache by id (the Mac client does). That's worth a sentence in PROTOCOL.md §4.
* **`stats.q` / `stats.win`** aren't documented in PROTOCOL.md; the Mac client ignores `win`.

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
