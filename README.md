<p align="center"><img src="logo.svg" width="120" alt="Darpan"></p>

<h1 align="center">Darpan</h1>

<p align="center"><b>Darpan</b> — Sanskrit for <i>mirror</i>. Your other computer, mirrored here:<br>
small, fast and private. Self-hosted remote desktop for a Linux workstation, used from a Mac (or any browser).</p>

---

## What you get

* **Low latency.** The screen is grabbed the instant it changes (X11 damage events, no fixed
  capture clock), encoded on the NVIDIA GPU's dedicated video engine (NVENC, ~3 ms), and sent
  immediately. The mouse pointer is drawn on your Mac, so moving it has zero lag.
* **Almost free while you train models.** Nothing runs until a viewer connects; a static screen
  sends nothing at all. Measured on this machine (RTX 4090, 2560×1440):

  | | cost |
  |---|---|
  | idle, nobody connected | 0 % CPU, 0 wake-ups, ~27 MB RAM (+ Tailscale ~33 MB) |
  | streaming your desktop | ~0.3 % of one CPU core, ~250 MB of GPU memory |
  | per changed frame | 2.1 ms capture + 3.2 ms encode, no CPU pixel copies |
  | typical desktop work | ~0.4 Mbit/s (adapts up to 40 Mbit/s for video/scrolling) |

  GPU memory is released ~15 s after you close or hide the viewer.
* **Private and secure.** No ports are opened and nothing is reachable from the internet: a
  bundled, unprivileged [Tailscale](https://tailscale.com) links only *your* devices with
  end-to-end WireGuard encryption, direct peer-to-peer whenever possible. On top of that the
  host asks for a password using a challenge–response (the password never crosses the wire)
  with brute-force lockout. Runs as your user — no root daemon. The clipboard is never read
  unless you're connected.
* **Everything you need, nothing you don't:** clipboard sync both ways, file upload (drag and
  drop), change the remote screen resolution (restored when you disconnect), quality/frame-rate
  presets, special keys (Super, Alt+Tab, Ctrl+Alt+Del…), full screen, a toolbar that collapses to
  a 46×14 px tab, and live stats.

## Install on the Linux computer (the one you want to reach)

```bash
sudo apt install ./dist/darpan_1.0.1_amd64.deb
```

The package is self-contained (Tailscale is inside); apt pulls in the few standard Ubuntu
packages it uses. It replaces an earlier *Porthole* install automatically, keeping your address,
password and Tailscale sign-in. Then open **Darpan** from the app grid (or run `darpan setup`):

1. **Sign in to Tailscale** — click *Sign in*, use any Google/Microsoft/GitHub/Apple account (free).
2. **Publish** — one click; if asked, enable HTTPS for your tailnet (one more click).
3. Note the **address** and **password** shown in the window.

For unattended use, open <https://login.tailscale.com/admin/machines>, find this computer and
choose **Disable key expiry** (otherwise it drops off the network after 180 days).

## Connect from the Mac

1. Install Tailscale on the Mac (App Store or <https://tailscale.com/download>) and sign in with
   the same account.
2. Open the address (e.g. `https://workstation.example.ts.net`) in Chrome or Safari and
   enter the password. Tick *Remember this device* to skip the password next time.
   *Tip:* in Chrome use *Install Darpan* (address bar) for an app window; in full screen Chrome
   also forwards shortcuts like ⌘W to the remote computer.
3. Or use the native Mac app (below): hardware video decoding, every shortcut goes to the remote computer,
   seamless clipboard sync.

Keyboard: ⌘ acts as Ctrl on the remote computer by default (⌘C/⌘V copy and paste as you expect);
switch it to Super in the keyboard menu. Keys are sent by position, so the Linux keyboard layout
decides the characters; *Type it* in the clipboard menu types arbitrary text.

## Mac app

1. Download `Darpan.dmg` from the [latest release](https://github.com/OWNER/darpan/releases/latest),
   open it and drag **Darpan** to **Applications**.
2. First launch: the app isn't notarized, so macOS blocks it once. Open it, then go to
   System Settings → Privacy & Security and click **Open Anyway**. Or run
   `xattr -dr com.apple.quarantine /Applications/Darpan.app` once.
3. Enter the address and password. With *Remember on this Mac*, only a key derived from the
   password is kept, in the Keychain, and it never leaves this Mac.
4. Optional: to send ⌘Tab, ⌘Space and Mission Control to the remote computer too, turn on *Send
   ⌘Tab, ⌘Space…* in the viewer's keyboard panel. Then allow Darpan in System Settings → Privacy
   & Security → Accessibility. The app is signed ad hoc, so after installing a new version macOS
   treats it as a new app: remove Darpan from the Accessibility list, add it again and restart it.

While the viewer is in front every key goes to the remote computer, ⌘Q and ⌘W included. These
shortcuts stay on the Mac:
* ⌃⌥⌘D disconnect
* ⌃⌥⌘F full screen
* ⌃⌥⌘⎋ release the keyboard (press again to capture it)

A minimised or hidden viewer stops the video. More in [mac/README.md](mac/README.md).

SHA-256 of `Darpan.dmg` 1.0.0: `9e7f47ac5c0c7a9a4f023818f214beae957e28ab9f3766a60286d460b43573d0`

## Everyday commands

```text
darpan status       address, password, who is connected
darpan password     show it · --set to choose your own · --generate for a new random one
darpan disconnect   kick every remote session
darpan doctor       check display, GPU encoder, network, service
darpan net          Tailscale status and whether your devices connect directly or via relay
```

Logs: `journalctl --user -u darpan -u darpan-net -f`

## Limitations (honest ones)

* **After a reboot someone must log in to the desktop** before Darpan can show it (it runs in
  your desktop session, not as root). For true unattended access enable *Automatic Login*
  (Settings → Users) — anyone with physical access then gets your desktop.
* X11 sessions only (Ubuntu's default with NVIDIA drivers); Wayland isn't supported yet.
* Without an NVIDIA GPU it falls back to software x264 (works, uses a few CPU cores while streaming).
* Keep your current paid remote-access app until you've confirmed Darpan works from the Mac.

## Uninstall

```bash
sudo apt remove darpan
rm -rf ~/.config/darpan ~/.local/state/darpan ~/.local/share/darpan   # settings, password, Tailscale state
```
Also remove the machine from <https://login.tailscale.com/admin/machines>.

## Repository layout

```text
PROTOCOL.md     the wire protocol — the contract every client implements
MAC_PROMPT.md   instructions for building the macOS app (for a Claude instance on the Mac)
linux/          host: Python daemon, C capture/NVENC encoder, browser client, packaging, tests
mac/            native macOS client (Swift)
dist/           built packages (.deb, .dmg) — not committed; attached to GitHub Releases
```
Developer notes: [linux/README.md](linux/README.md), [mac/README.md](mac/README.md).
