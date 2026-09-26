# Build the Darpan macOS app

You are a Claude instance on the owner's Mac, in a clone of `github.com/OWNER/darpan`
(private). The Linux host — the machine being controlled — is finished and running. Your job is
the **native macOS client** in `mac/`, shipped as `dist/Darpan.dmg` and attached to the GitHub
release. The owner uses it from home to work on a Linux workstation that trains ML models, so it
must feel instant for typing and cost almost nothing. Work autonomously; post short progress
updates; ask the owner only for the things listed in §0.

## 0. Before you start

Run and report: `sw_vers`, `uname -m`, `xcode-select -p`, `swift --version`, `gh auth status`,
`git config user.name`, `git config user.email`, `git status`, `git log --oneline -3`.

* No Command Line Tools → ask the owner to run `xcode-select --install`.
* `gh` missing/not logged in → ask the owner to install it (`brew install gh`) and run
  `gh auth login` (they can type `! gh auth login` in Claude Code).
* No git identity → ask the owner for name/email; never invent one.
* Ask the owner for the **host address** (`https://<machine>.<tailnet>.ts.net`) and **password**
  (shown in the Darpan window on Linux, or `darpan status`). Check reachability with
  `curl -sS <address>/api/info`. If it fails: Tailscale must be running and signed in on this
  Mac with the same account, and the Linux setup steps in `README.md` must be done — tell the
  owner which one is missing, then continue with everything that doesn't need the host.
* **Never write the address or password into any file in the repo.** For live tests read them
  from environment variables (`DARPAN_URL`, `DARPAN_PASSWORD`) or the Keychain.

## 1. Read first (in this order)

1. `PROTOCOL.md` — the wire contract. Implement it exactly; don't change it.
2. `linux/web/app.js` — a complete, tested client for the same protocol (browser). Port its
   logic: auth, Annex-B→AVCC, ack-after-decode, cursor, clipboard, uploads, resolution menu,
   reconnect, stats. When unsure how something should behave, it is the reference.
3. `README.md` and `linux/README.md` — the product, and how a frame travels end to end.

## 2. Priorities

1. **Latency** (typing must feel local). 2. **Efficiency** (no busy loops, no work while idle or
hidden). 3. Correctness and security. 4. Polish. **Apple frameworks only — no dependencies.**

## 3. Architecture (Swift 5.9+, SwiftPM, not sandboxed)

Deployment target: macOS 13, or 12 if the owner's Mac is older (nothing below needs more).

* **Connection** — `Network.framework`: `NWConnection` to `NWEndpoint.url(<address>/ws)` with
  `NWProtocolWebSocket.Options` (`autoReplyPing = true`, max message 8 MiB), TLS with default
  certificate validation (valid Let's Encrypt cert on `*.ts.net`), `NWProtocolTCP.Options.noDelay
  = true`. Omit the `Origin` header. Refuse plain `ws://` except to `localhost`.
* **Auth** — PBKDF2-HMAC-SHA256 via CommonCrypto `CCKeyDerivationPBKDF`, HMAC via CryptoKit,
  label `darpan-auth-v1`; password NFC-normalised (`precomposedStringWithCanonicalMapping`).
  Keychain stores the **derived key** (never the password) + salt + iter per host
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); reuse it while `hello` carries the same
  salt/iter, otherwise ask for the password again. `auth.client` = `"Darpan for Mac 1.0.0 on
  macOS <version>"`, `ver` = `"1.0.0"`. Known-answer test:

  ```text
  password  "correct horse battery"
  salt      c2FsdHNhbHRzYWx0c2FsdA==        iter 200000
  nonce     AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=
  key (hex) a58c2cefe9e01e0464dad113872d0867db9889f547e517fb39ce046b3506a845
  proof     AG+vUe6kdYyGhR8kh0ntx1CxNRsbCrdjnHuzYug1Sgg=
  ```
* **Video** — parse the 16-byte VIDEO header; drop frames whose stream id isn't the latest
  `stream`. Split Annex-B NALs; on key frames build a `CMVideoFormatDescription` with
  `CMVideoFormatDescriptionCreateFromH264ParameterSets` (NAL length 4), recreating the session when
  SPS/PPS change. Wrap length-prefixed NALs (drop SPS/PPS/AUD) in `CMBlockBuffer`/`CMSampleBuffer`
  and decode with a **`VTDecompressionSession`** (hardware, `kVTDecompressionPropertyKey_RealTime
  = true`, output `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) on a serial queue.
  **Ack each frame from the decode callback.** Then display the *decoded* `CVPixelBuffer`
  immediately — wrap it in an uncompressed `CMSampleBuffer` enqueued into an
  `AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_DisplayImmediately`, or set it as
  a `CALayer`'s contents. (Don't feed compressed frames to the display layer: you'd lose the
  decode callback the protocol's flow control needs.) Keep the decoder's BT.709 colour
  attachments. The video view is plain AppKit/Core Animation — never re-render SwiftUI per frame.
  On decode error: `{"t":"kf"}` and wait for the next key frame. REFRESH-flagged frames carry an
  old capture timestamp: exclude them from latency stats.
* **Timing** — while connected, hold `ProcessInfo.processInfo.beginActivity(options:
  [.userInitiated, .latencyCritical], reason:)` so App Nap / timer coalescing never add delay;
  end it on disconnect.
* **Keyboard** — viewer `NSView` as first responder plus `NSEvent.addLocalMonitorForEvents` for
  `.keyDown/.keyUp/.flagsChanged` (AppKit doesn't deliver key-up for ⌘ combos to responders; if
  some are still lost, send ⌘ combos as down+up like the web client). Map `event.keyCode` with the
  table in §4. Modifiers come from `.flagsChanged`: diff against the previous flags, left/right by
  keyCode. ⌘ → `ControlLeft/Right` by default, user-switchable to `MetaLeft/Right` (Super).
  CapsLock → down+up per toggle. OS auto-repeat `keyDown`s → extra `d:true`. Window resigns key or
  app deactivates → `{"t":"rel"}`. IME input (`insertText`) → `txt`.
* **Mouse** — `acceptsMouseMovedEvents` + a tracking area; send `mm` for every move (skip
  duplicates) in **stream pixels**, accounting for letterboxing and `backingScaleFactor` (also
  when the window moves to another display). Buttons → protocol `b`: left 0, right 2,
  `otherMouse` buttonNumber 2 → 1 (middle), 3 → 3 (back), 4 → 4 (forward).
  **Scroll sign:** AppKit deltas describe content movement, the protocol wants scroll direction:
  `dy = −scrollingDeltaY × k`, `dx = −scrollingDeltaX × k`, with `k = 2.4` when
  `hasPreciseScrollingDeltas` (trackpad pixels; 50 px ≈ one notch) and `k = 120` otherwise (one
  wheel notch = one notch). Keep fractional remainders; the OS already applied natural scrolling.
* **System shortcuts (optional toggle "Capture ⌘Tab / ⌘Space")** — a `CGEventTap`
  (`.cgSessionEventTap`) active only while the viewer window is key; forwards and swallows
  keyDown/keyUp/flagsChanged. Needs Accessibility permission (`AXIsProcessTrustedWithOptions`).
  Escape hatch ⌃⌥⌘Esc releases capture; never leave the tap running after quit or disconnect.
* **Cursor** — `cur` → `NSCursor(image:hotSpot:)`, cache by id, scale remote pixels to the view
  scale. id 0 → hide the cursor, but only while it's inside the viewer (unhide on exit).
* **Clipboard** — host `clip` → `NSPasteboard`, except the first one after connecting (don't
  clobber the Mac's clipboard). Mac → host: poll `NSPasteboard.general.changeCount` at 2 Hz only
  while connected and the app is active; send changes that didn't just come from the host.
* **Files** — drag & drop onto the viewer → PROTOCOL §7 (256 KiB chunks, ≤ 512 KiB un-acked).
* **Visibility** — window minimised/occluded (`NSWindow.occlusionState`) → `stop`; visible again
  → `start` (the host then idles its GPU encoder).
* **UI** — SwiftUI for windows/forms, AppKit where it's faster.
  * Connect window: saved hosts (name + URL in `UserDefaults`), password, "Remember", clear errors:
    wrong password, locked (countdown from `retry`), unreachable → "Is Tailscale running?".
  * Viewer window: remote screen fills it (Fit / Actual pixels). A **collapsed pill** top-centre
    (~46×14 pt, like the web client) expanding to: full screen · display (remote resolution from
    `modes`, scaling, quality Auto/Low/Balanced/High/Max = 0/3000/10000/20000/50000 kbps, fps
    30/60/120) · keys (Super, Alt+Tab, Alt+F4, Ctrl+Alt+T, Ctrl+Alt+Del, PrtSc, Esc, Lock = Super+L,
    workspace ←/→) · clipboard (view, send, type via `txt`) · upload · stats · disconnect. Mirror
    them in the menu bar (with a Disconnect shortcut that works even when keys are captured).
  * Stats overlay: fps, Mbps, RTT (ping every 2 s), decode ms, capture→display estimate, host
    `stats`. Native full screen. Auto-reconnect with backoff using the stored key.

## 4. macOS virtual key code → W3C `code`

```swift
let keyCodeMap: [UInt16: String] = [
  0x00:"KeyA",0x01:"KeyS",0x02:"KeyD",0x03:"KeyF",0x04:"KeyH",0x05:"KeyG",0x06:"KeyZ",0x07:"KeyX",
  0x08:"KeyC",0x09:"KeyV",0x0A:"IntlBackslash",0x0B:"KeyB",0x0C:"KeyQ",0x0D:"KeyW",0x0E:"KeyE",
  0x0F:"KeyR",0x10:"KeyY",0x11:"KeyT",0x12:"Digit1",0x13:"Digit2",0x14:"Digit3",0x15:"Digit4",
  0x16:"Digit6",0x17:"Digit5",0x18:"Equal",0x19:"Digit9",0x1A:"Digit7",0x1B:"Minus",0x1C:"Digit8",
  0x1D:"Digit0",0x1E:"BracketRight",0x1F:"KeyO",0x20:"KeyU",0x21:"BracketLeft",0x22:"KeyI",
  0x23:"KeyP",0x24:"Enter",0x25:"KeyL",0x26:"KeyJ",0x27:"Quote",0x28:"KeyK",0x29:"Semicolon",
  0x2A:"Backslash",0x2B:"Comma",0x2C:"Slash",0x2D:"KeyN",0x2E:"KeyM",0x2F:"Period",0x30:"Tab",
  0x31:"Space",0x32:"Backquote",0x33:"Backspace",0x35:"Escape",0x36:"MetaRight",0x37:"MetaLeft",
  0x38:"ShiftLeft",0x39:"CapsLock",0x3A:"AltLeft",0x3B:"ControlLeft",0x3C:"ShiftRight",
  0x3D:"AltRight",0x3E:"ControlRight",0x40:"F17",0x41:"NumpadDecimal",0x43:"NumpadMultiply",
  0x45:"NumpadAdd",0x47:"NumLock",0x48:"AudioVolumeUp",0x49:"AudioVolumeDown",0x4A:"AudioVolumeMute",
  0x4B:"NumpadDivide",0x4C:"NumpadEnter",0x4E:"NumpadSubtract",0x4F:"F18",0x50:"F19",
  0x51:"NumpadEqual",0x52:"Numpad0",0x53:"Numpad1",0x54:"Numpad2",0x55:"Numpad3",0x56:"Numpad4",
  0x57:"Numpad5",0x58:"Numpad6",0x59:"Numpad7",0x5A:"F20",0x5B:"Numpad8",0x5C:"Numpad9",
  0x5D:"IntlYen",0x5E:"IntlRo",0x5F:"NumpadComma",0x60:"F5",0x61:"F6",0x62:"F7",0x63:"F3",
  0x64:"F8",0x65:"F9",0x66:"Lang2",0x67:"F11",0x68:"Lang1",0x69:"F13",0x6A:"F16",0x6B:"F14",
  0x6D:"F10",0x6E:"ContextMenu",0x6F:"F12",0x71:"F15",0x72:"Insert",0x73:"Home",0x74:"PageUp",
  0x75:"Delete",0x76:"F4",0x77:"End",0x78:"F2",0x79:"PageDown",0x7A:"F1",0x7B:"ArrowLeft",
  0x7C:"ArrowRight",0x7D:"ArrowDown",0x7E:"ArrowUp",
]
```
(ISO keyboards swap `IntlBackslash`/`Backquote` physically; this matches Chrome. `Fn` isn't sent.)

## 5. Layout of `mac/`

```text
mac/Package.swift
mac/Sources/DarpanCore/   protocol types, auth, Annex-B/AVCC, key map — no UI, testable
mac/Sources/Darpan/       the app (AppKit/SwiftUI, VideoToolbox, input, UI)
mac/Sources/SelfTest/       test runner executable (see §7) — or Tests/ if XCTest exists
mac/build.sh                one command: test → build → .app → sign → .dmg
mac/assets/logo-1024.png    icon source (exists)
mac/README.md               update: how to build, run, install
mac/NOTES.md                anything the Linux side should fix (create only if needed)
```

## 6. Build and package — `mac/build.sh`

1. Run the self-tests; stop on failure.
2. `swift build -c release` (universal `--arch arm64 --arch x86_64` only if the toolchain
   supports it; otherwise the Mac's own arch is fine).
3. Assemble `dist/Darpan.app`: `Contents/MacOS/Darpan`, `Contents/Info.plist`
   (`CFBundleIdentifier` `dev.darpan.Darpan`, `CFBundleName` Darpan,
   `CFBundleShortVersionString` 1.0.0, `CFBundleVersion` 1, `LSMinimumSystemVersion`,
   `NSHighResolutionCapable` true, `CFBundleIconFile` AppIcon), `Contents/Resources/AppIcon.icns`
   built from `mac/assets/logo-1024.png` with `sips` + `iconutil`.
4. Sign: if `DARPAN_SIGN_ID` names a certificate in the keychain use it, else ad-hoc
   (`codesign --force --deep -s -`). A stable self-signed "code signing"
   certificate (Keychain Access → Certificate Assistant) keeps the Accessibility permission across
   rebuilds; with ad-hoc signing macOS asks again after every rebuild — say so in the README.
5. DMG: stage `Darpan.app` + a symlink to `/Applications`, then
   `hdiutil create -volname Darpan -srcfolder <stage> -ov -format UDZO dist/Darpan.dmg`.
6. Print the DMG path and its `shasum -a 256`.

Everything must work with only the Command Line Tools installed.

## 7. Test

* **Self-tests** (XCTest ships with Xcode, not the Command Line Tools — if `import XCTest` fails,
  put the tests in the `SelfTest` executable that exits non-zero on failure): the auth vector in
  §3, Annex-B splitting incl. 3- and 4-byte start codes, avcC/format-description creation from a
  real SPS/PPS, key-map sanity, wheel-sign conversion.
* **Live, against the owner's host**: first open the address in Safari on this Mac to confirm the
  host works, then your app. Check: video appears, typing latency (stats), mouse and scroll
  (direction!), ⌘C/⌘V both ways, file drop lands in `~/Downloads/Darpan/` on Linux, resolution
  change and that it reverts on disconnect, minimise → host stops encoding (stats stop), reconnect
  after toggling Wi-Fi, wrong password shows the error. Don't leave the host in a changed
  resolution when you finish.
* Measure and report: decode ms, capture→display ms, app CPU % while streaming and while idle.

## 8. Git

* Before starting: `git checkout main && git pull --rebase`.
* Commit in logical steps with clear messages (e.g. `mac: connection + auth`, `mac: video
  pipeline`, `mac: input`, `mac: UI`, `mac: packaging`). Commit only sources, scripts and docs —
  never `dist/`, `.build/`, `.app`, `.dmg`, secrets, the host address or the password.
* Before every push: `git pull --rebase origin main` (the Linux side may have pushed meanwhile —
  conflicts can only be in `README.md`; keep both sides), then `git push origin main`.
  Never force-push or rewrite history.
* Stay inside `mac/` plus a "Mac app" section in `README.md`. Don't edit `linux/` or
  `PROTOCOL.md`; if the host or protocol looks wrong, write it up in `mac/NOTES.md`, push it, and
  tell the owner.

## 9. Release

```bash
bash mac/build.sh
gh release view v1.0.0 >/dev/null 2>&1 || gh release create v1.0.0 --title "Darpan 1.0.0" --notes ""
gh release upload v1.0.0 dist/Darpan.dmg --clobber
gh release view v1.0.0 --json body -q .body > /tmp/notes.md   # then append the Mac section:
gh release edit v1.0.0 --notes-file /tmp/notes.md
```
The appended Mac section: install (open the DMG, drag Darpan to Applications), first launch of a
downloaded copy (System Settings → Privacy & Security → *Open Anyway*, or
`xattr -dr com.apple.quarantine /Applications/Darpan.app`), Accessibility permission for
shortcut capture, and the DMG's SHA-256. Put the same install notes in the README's Mac section.

## 10. Definition of done

- [ ] `bash mac/build.sh` passes self-tests and produces `dist/Darpan.dmg` from a clean clone
- [ ] every live check in §7 passes against the owner's host (or the owner was told which
      couldn't be run and why)
- [ ] `README.md` Mac section + `mac/README.md` written
- [ ] all work committed and pushed to `main`; working tree clean; no secrets committed
- [ ] DMG uploaded to release v1.0.0 and the release notes updated
- [ ] the owner has the app: offer to copy `dist/Darpan.app` to `/Applications`

## 11. Final report to the owner

A short message: what was built, how to install and launch it, the measured numbers (§7), anything
that didn't pass or wasn't tested, links to the commit and the release, and anything written to
`mac/NOTES.md` for the Linux side.
