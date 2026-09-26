# Build the Porthole macOS app

You are working on a Mac, in a clone of this repository. The Linux host (the machine being
controlled) is finished and running. Your job is the **native macOS client** in `mac/`, shipped
as `dist/Porthole.dmg`. The owner uses it from home to work on a Linux workstation that trains ML
models, so it must feel instant for typing and cost almost nothing.

## Read first (in this order)

1. `PROTOCOL.md` — the wire contract. Implement it exactly; don't change it.
2. `linux/web/app.js` — a complete, tested client for the same protocol (browser). Port its
   logic: auth, Annex-B→AVCC conversion, ack-after-decode, cursor, clipboard, uploads, resolution
   menu, reconnect, stats. When unsure how something behaves, it is the reference.
3. `README.md` — what the product is and how the owner connects (Tailscale on both machines).

## Priorities

1. **Latency** (typing must feel local). 2. **Efficiency** (no busy loops, no idle work).
3. Correctness and security. 4. Polish. **No third-party dependencies** — Apple frameworks only.

## Architecture (Swift 5.9+, SwiftPM, macOS 13+, not sandboxed)

* **Connection** — `Network.framework` `NWConnection` with `NWProtocolWebSocket`, TLS, and
  `NWProtocolTCP.Options.noDelay = true`, to `wss://<host>.<tailnet>.ts.net/ws` (valid Let's
  Encrypt certificate; the Mac runs Tailscale). Handle text (JSON) and binary messages. Send the
  `Origin` header only if it equals the host (or omit it).
* **Auth** — PBKDF2-HMAC-SHA256 with CommonCrypto `CCKeyDerivationPBKDF`, HMAC with CryptoKit,
  label `porthole-auth-v1`. Password NFC-normalised (`precomposedStringWithCanonicalMapping`).
  Store the **derived key** (never the password) plus salt/iter in the Keychain per host; reuse
  it while `hello` carries the same salt/iter. Known-answer test (put it in a unit test):

  ```text
  password  "correct horse battery"
  salt      c2FsdHNhbHRzYWx0c2FsdA==        iter 200000
  nonce     AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=
  key (hex) a58c2cefe9e01e0464dad113872d0867db9889f547e517fb39ce046b3506a845
  proof     wyZGzNpll1CwX3ZcThEoUAHMf5d8zkgbExTI/lYsAEE=
  ```
* **Video** — parse the 16-byte VIDEO header, split Annex-B NALs, build a
  `CMVideoFormatDescription` from SPS/PPS (`CMVideoFormatDescriptionCreateFromH264ParameterSets`,
  4-byte NAL length) on key frames (recreate when SPS/PPS change), wrap length-prefixed NALs
  (drop SPS/PPS/AUD) in `CMBlockBuffer`/`CMSampleBuffer`. Decode with `VTDecompressionSession`
  (`kVTDecompressionPropertyKey_RealTime = true`, hardware decoder) on a dedicated queue and
  **ack every frame from the decode callback**. Display with the least buffering you can
  measure: start with `AVSampleBufferDisplayLayer` (+ `kCMSampleAttachmentKey_DisplayImmediately`)
  or set the decoded `CVPixelBuffer` as a layer's contents; a `CAMetalLayer` path is welcome if it
  measurably lowers latency. On decoder error: send `{"t":"kf"}` and wait for the next key frame.
  Frames flagged REFRESH carry an old capture timestamp — exclude them from latency stats.
* **Input** — an `NSView` that is first responder; `NSEvent.addLocalMonitorForEvents` for
  `.keyDown/.keyUp/.flagsChanged` (AppKit doesn't deliver key-up for ⌘ combos to responders —
  if you still lose them, send ⌘-combos as down+up like the web client). Map `event.keyCode` with
  the table below; modifiers come from `.flagsChanged` (compare with previous flags to get
  down/up; left/right via keyCode). ⌘ → `ControlLeft/Right` by default, user-switchable to
  `MetaLeft/Right`. CapsLock: down+up per toggle. Send auto-repeat `keyDown`s as extra `d:true`.
  Mouse: absolute `mm` in stream pixels (handle letterboxing and Retina), buttons 0–4, scroll:
  `scrollingDeltaY` with `hasPreciseScrollingDeltas` ≈ pixels → `×2.4` units (1 notch = 120 ≈
  50 px), line deltas `×40`; respect the user's natural-scrolling setting as the OS reports it.
  On window resign-key: send `{"t":"rel"}`.
* **System shortcuts (optional toggle "Capture ⌘Tab / ⌘Space")** — a `CGEventTap` on
  `.cgSessionEventTap` active only while the viewer window is key, forwarding keyDown/keyUp/
  flagsChanged and swallowing them. Needs Accessibility permission (`AXIsProcessTrustedWithOptions`);
  provide an escape (e.g. ⌃⌥⌘Esc releases capture) and never leave the tap enabled after quit.
* **Cursor** — `cur` messages → `NSCursor(image:hotSpot:)` (cache by id; id 0 → hide). Image is
  in remote pixels: scale by the on-screen scale so it looks right on Retina.
* **Clipboard** — host `clip` → `NSPasteboard` (not on the first message after connect: don't
  clobber the Mac's clipboard). Local → host: poll `NSPasteboard.general.changeCount` at 2 Hz
  **only while connected and the app is active**; send when it changes (not echoing what came
  from the host).
* **Files** — drag & drop onto the viewer → PROTOCOL §7 (256 KiB chunks, ≤512 KiB un-acked).
* **Visibility** — when the window is minimised/occluded (`NSWindow.occlusionState`) send
  `stop`; on visible send `start` (the host then idles the GPU encoder).
* **UI** — SwiftUI where it helps, AppKit where it's faster.
  * Connect window: saved hosts (name + URL), password field, "Remember", clear errors (wrong
    password, locked with countdown, unreachable → "Is Tailscale running?").
  * Viewer window: the remote screen fills it (Fit / Actual pixels). A **collapsed pill** at the
    top centre (like the web client, ~46×14 pt) that expands to: full screen, display (remote
    resolution from `modes`, scaling, quality Auto/Low/Balanced/High/Max = 0/3000/10000/20000/
    50000 kbps, fps 30/60/120), keys (Super, Alt+Tab, Alt+F4, Ctrl+Alt+T, Ctrl+Alt+Del, PrtSc,
    Esc, Lock = Super+L, workspace ←/→), clipboard (view/send/type text via `txt`), upload,
    stats, disconnect. Also expose these in the menu bar with shortcuts.
  * Stats overlay: fps, Mbps, RTT (ping every 2 s), decode ms, capture→display estimate, host
    `stats`. Native full screen. Auto-reconnect with backoff using the stored key.
  * App icon: `mac/assets/logo-1024.png` (from `logo.svg`).

### macOS virtual key code → W3C `code`

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
(ISO keyboards swap `IntlBackslash`/`Backquote` physically; keep the table, it matches Chrome.)

## Build, package, ship

* `mac/Package.swift` (executable target `Porthole`, test target) and `mac/build.sh`:
  `swift build -c release` → assemble `Porthole.app` (Info.plist: `CFBundleIdentifier`
  `dev.porthole.Porthole`, `LSMinimumSystemVersion` 13.0, `NSHighResolutionCapable`,
  icon from `mac/assets/logo-1024.png` via `sips` + `iconutil`) → ad-hoc sign
  (`codesign --force --deep -s -`) → `hdiutil create … -format UDZO dist/Porthole.dmg`.
* Everything must build with only Xcode Command Line Tools if possible (`xcode-select --install`).
* Don't commit build outputs (`.gitignore` covers `dist/`, `mac/.build/`).

## Test

* Unit tests: the auth vector above, Annex-B splitting/AVCC building, key map sanity.
* Live: ask the owner for the address and password (the host is at
  `https://<machine>.<tailnet>.ts.net`, shown in the Linux app / `porthole status`). First
  confirm the browser client works in Safari from this Mac, then your app. Check: video,
  typing latency (stats), mouse/scroll, ⌘C/⌘V both ways, file drop, resolution change (and that it
  reverts on disconnect), window minimise → host stops encoding, reconnect after Wi-Fi blip.
* Report measured numbers (decode ms, capture→display ms, CPU of the app while streaming).

## Rules

* Work only in `mac/` (plus `dist/`, and a short "Mac app" section in `README.md`). If the
  protocol or host looks wrong, don't change `linux/` or `PROTOCOL.md` — write it up in
  `mac/NOTES.md` for the Linux side.
* Commit to `main` with clear messages and push. Attach the DMG to the release:
  `gh release upload v1.0.0 dist/Porthole.dmg --clobber` (or create `v1.0.0` if missing).
