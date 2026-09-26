# Darpan for Mac

Native macOS client for Darpan (Swift, AppKit + SwiftUI, VideoToolbox, Network.framework; no
dependencies). It speaks [`../PROTOCOL.md`](../PROTOCOL.md) and mirrors the browser client
[`../linux/web/app.js`](../linux/web/app.js). macOS 13 or later, Apple silicon or Intel.

Install and first launch: see *Mac app* in the [main README](../README.md#mac-app).

## Using it

* **Connect window**: the computer's address (`https://<machine>.<tailnet>.ts.net`), the password,
  *Remember on this Mac*. The clock button lists recent computers. A remembered computer
  connects at launch.
* **Viewer**: the small pill at the top edge opens the toolbar (hover or click; drag it sideways
  to move it): full screen, display (remote resolution, Fit / Actual size, quality, frame rate),
  keys (Super, Alt+Tab, Ctrl+Alt+Del…, what ⌘ sends, system shortcuts, scrolling), clipboard,
  send files, stats, disconnect. The *Connection* and *View* menus have the same commands.
* **Keyboard**: while the viewer is in front every key goes to the remote computer, ⌘Q and ⌘W
  included. ⌘ is Ctrl there by default (⌘C / ⌘V copy and paste), or Super. Always on the Mac:
  * ⌃⌥⌘D disconnect
  * ⌃⌥⌘F full screen
  * ⌃⌥⌘⎋ release the keyboard (Mac shortcuts work again; press again to capture)
* **System shortcuts** (⌘Tab, ⌘Space, Mission Control): off by default. Turn on *Send ⌘Tab,
  ⌘Space…* in the keys panel and allow Darpan in System Settings → Privacy & Security →
  Accessibility. They're only taken while the viewer is the front window.
* **Clipboard**: text copied on either side is available on the other. Items that password
  managers mark as concealed are only sent when you paste them with ⌘V.
* **Files**: drop files on the window (or use the toolbar). They land in `~/Downloads/Darpan/` on
  the remote computer. Folders aren't sent; zip them first.
* **Efficiency**: a minimised, hidden or fully covered window stops the video (the remote encoder
  idles). Display sleep isn't prevented.

## Building

```sh
bash mac/build.sh        # self-tests, universal release build, dist/Darpan.app + dist/Darpan.dmg
```

Only the Command Line Tools are needed. Set `DARPAN_SIGN_ID` to a *Developer ID Application*
identity to sign with it; otherwise the app is signed ad hoc.

```
Sources/DarpanCore/   protocol, auth, Annex-B → AVCC, VideoToolbox decoder, key map, client
Sources/Darpan/       the app: windows, video view, input, clipboard, toolbar, menus
Sources/SelfTest/     `swift run SelfTest` (XCTest isn't part of the Command Line Tools)
tools/FakeHost/       a stand-in host on this Mac, for testing without a tailnet
assets/logo-1024.png  app icon source
```

## Testing on one Mac

```sh
cd mac
swift run FakeHost                     # ws://localhost:47491, password "darpan-test"
DARPAN_URL=http://localhost:47491 DARPAN_PASSWORD=darpan-test swift run Darpan
```

FakeHost streams a test pattern (colour bars, a moving bar, a 1-pixel checkerboard, a crosshair
where it believes the pointer is, the last key and typed text) and prints every input message.
Commands on its stdin exercise the failure paths: `clip <text>`, `notice <text>`, `kick`,
`restart`, `drop`, `stall`, `lock`, `quit`.

Environment variables (for tests; nothing is stored): `DARPAN_URL`, `DARPAN_PASSWORD`,
`DARPAN_LOG_STATS=1` (stats line on stderr every 2 s). Debug builds also read
`DARPAN_DEBUG_CMDS=<file>`: commands appended to that file drive the app without Accessibility
or Screen Recording permissions (synthetic keys and clicks through the normal event path,
window actions, snapshots); see `Sources/Darpan/DebugHooks.swift`. Release builds don't contain it.
