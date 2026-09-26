# Darpan for Mac

Native macOS client for Darpan (Swift, AppKit + SwiftUI, VideoToolbox, Network.framework, and
libtailscale for the built-in tailnet connection). It speaks [`../PROTOCOL.md`](../PROTOCOL.md) and mirrors the browser client
[`../linux/web/app.js`](../linux/web/app.js). macOS 14 or later, Apple silicon or Intel.

Install and first launch: see *Mac app* in the [main README](../README.md#mac-app).

## Using it

* **Private network**: Darpan has Tailscale built in (libtailscale), so the Tailscale app isn't
  needed. The first time, click **Sign in with Tailscale**; the Mac appears on the tailnet as
  `darpan-<Mac name>`. Turn off its key expiry in the admin console. Only Darpan's own connection
  uses it: no VPN, no DNS changes. The node's keys are in
  `~/Library/Application Support/Darpan/tailscale`; delete that folder to sign out. The ⚙︎ menu can
  switch to *This Mac's network* instead (e.g. the Tailscale app).
* **Connect window**: *Your computers* lists the Linux computers on your tailnet that run Darpan,
  found by themselves, plus the ones you've used. Click one to connect. The first time, enter the
  password Darpan shows on that computer (or `darpan password` there); with *Remember on this
  Mac* it's one click from then on. Right-click a computer you've used to forget it (a computer that's found by itself stays while it's online).
  *Other address…* takes an address by hand. A remembered computer connects at launch.
* **Viewer**: the small capsule at the upper right opens the toolbar when you point at it; drag it
  by its grip to move it anywhere. It has full screen, display (remote resolution, Fit / Actual
  size, quality, frame rate), keys (Super, Alt+Tab, Ctrl+Alt+Del…, what ⌘ sends, system shortcuts,
  scrolling), send files, sound, stats, disconnect. The *Connection* and *View* menus have the same
  commands, plus the clipboard ones (*Type Clipboard on Remote* for places where pasting doesn't work).
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
* **Files**: the toolbar's **Files** button (or Connection → Files…) opens two panes, this Mac on the
  left and the remote computer on the right. Select files or folders, then **Send** or **Receive**, or
  drag between the panes. Files dropped on the viewer land on the remote computer's desktop.
* **Updates**: once a day while it's open, Darpan checks GitHub for a newer release, and asks before
  installing it. It's the only request Darpan makes outside the tailnet. The ⚙︎ menu's *Check for
  Updates Automatically* turns it off; *Darpan → Check for Updates…* checks at once.
* **Sound**: the remote computer's sound plays on the Mac. It's on by default; the speaker button in
  the toolbar, or View → Play Sound, mutes it. It keeps playing while the viewer is hidden, and the
  Mac's audio device is used only while sound actually arrives (it's released after 2 s without any).
* **Efficiency**: a minimised, hidden or fully covered window stops the video (the remote encoder
  idles). Display sleep isn't prevented.

## Building

```sh
bash mac/build.sh        # self-tests, universal release build, dist/Darpan.app + dist/Darpan.dmg
```

Needs the Command Line Tools and Go 1.25.5 or later (on PATH, or in `~/.local/go`), which builds
libtailscale at a pinned commit (`tailscale/build-libtailscale.sh`). The first build downloads Go
modules. Plain `swift build` needs that script run once first. Set `DARPAN_SIGN_ID` to a *Developer ID Application*
identity to sign with it; otherwise the app is signed ad hoc.

```
Sources/DarpanCore/   protocol, auth, Annex-B → AVCC, VideoToolbox decoder, key map, client
Sources/CTailscale/   module map for libtailscale's C API (built into .build/libtailscale)
tailscale/            build-libtailscale.sh (pinned commit, universal c-archive)
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
