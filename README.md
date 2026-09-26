> [!IMPORTANT]
> **Private pre-release.** Do not publish this repository, its history, or its releases as-is.
> Publish only from a fresh repository created from a sanitized snapshot — see
> [Publishing](#publishing).

<p align="center"><img src="logo.svg" width="120" alt="Darpan"></p>

<h1 align="center">Darpan</h1>

<p align="center"><b>Darpan</b> (Sanskrit: <i>mirror</i>) — a fast, private, self-hosted remote desktop.<br>
The host runs on a Linux workstation; clients are a native macOS app and any modern browser.</p>

---

## Highlights

* **Low latency.** The screen is captured the moment it changes (X11 damage events, no fixed
  capture clock), encoded on the GPU's dedicated video engine (NVENC, ~3 ms) and sent at once.
  The pointer is drawn locally on the client, so it never lags.
* **Near-zero cost on a busy machine.** Nothing runs until a viewer connects, and a static screen
  sends nothing. Measured on a 2560×1440 desktop with an RTX 4090:

  | | cost |
  |---|---|
  | idle, no viewer | 0 % CPU, no wake-ups, ~27 MB RAM (+ ~33 MB for the network daemon) |
  | streaming | ~0.3 % of one CPU core, ~250 MB of GPU memory |
  | per changed frame | 2.1 ms capture + 3.2 ms encode, no CPU pixel copies |
  | typical desktop work | ~0.4 Mbit/s (adapts up to 40 Mbit/s for video and scrolling) |

  GPU memory is released ~15 s after the viewer closes or is hidden.
* **Private by design.** No ports are opened and nothing is reachable from the internet. A
  bundled, unprivileged [Tailscale](https://tailscale.com) node connects only your own devices,
  end-to-end encrypted with WireGuard and peer-to-peer whenever possible. The host also requires a
  password, verified by challenge–response (it never crosses the network) with brute-force
  lockout. It runs as your user, with no root daemon; the clipboard is read only while a viewer
  is connected.
* **Complete, not bloated.** Two-way clipboard sync, file upload by drag and drop, remote screen
  resolution changes (reverted on disconnect), quality and frame-rate presets, special keys,
  full screen, a toolbar that collapses to a small tab, and live statistics.

## Requirements

* **Host:** Ubuntu 24.04 (or similar) on an X11 session; an NVIDIA GPU for hardware encoding
  (other GPUs fall back to software encoding).
* **Clients:** macOS 14 or later for the native app; Chrome, Safari, Edge or Firefox for the
  browser client.

## Install the host

```bash
sudo apt install ./darpan_<version>_amd64.deb
```

The package is self-contained (the Tailscale node is included); apt installs the few standard
packages it depends on. Then open **Darpan** from the application grid, or run `darpan setup`:

1. **Sign in** to Tailscale (any Google, Microsoft, GitHub or Apple account; free for personal use).
2. **Publish** the host on your tailnet; enable HTTPS for the tailnet if prompted.
3. Note the **address** and **password** shown.

For unattended use, disable key expiry for the host in the Tailscale admin console
(<https://login.tailscale.com/admin/machines>); otherwise the device must sign in again after
180 days.

## Connect

**macOS app.** Download `Darpan.dmg` from the latest release, open it and drag **Darpan** to
**Applications**. The app is not notarized: on first launch, allow it in System Settings →
Privacy & Security (**Open Anyway**). Enter the host address and password; with *Remember on this
Mac* only a key derived from the password is kept, in the Keychain. See
[mac/README.md](mac/README.md) for shortcut capture and other details.

**Browser.** On a device signed in to the same tailnet, open the host address
(`https://<machine>.<tailnet>.ts.net`) and enter the password. In Chrome, *Install Darpan* gives
an app window, and in full screen shortcuts such as ⌘W reach the remote computer.

**Keyboard.** ⌘ acts as Ctrl on the remote computer by default (so ⌘C/⌘V copy and paste as
expected) and can be switched to Super. Keys are sent by position, so the host's keyboard layout
determines the characters; *Type it* in the clipboard panel types arbitrary text.

## Command line

```text
darpan status       address, password and connected devices
darpan password     show the password; --set to choose one, --generate for a new random one
darpan disconnect   end all remote sessions
darpan doctor       check the display, GPU encoder, network and service
darpan net          network status and whether devices connect directly or via a relay
```

Logs: `journalctl --user -u darpan -u darpan-net -f`

## Known limitations

* The host runs in the desktop session, so after a reboot someone must log in before Darpan can
  show the screen. Automatic login removes this requirement, at the cost of physical security.
* X11 sessions only; Wayland is not supported yet.
* Without an NVIDIA GPU, encoding falls back to software x264, which uses several CPU cores while
  streaming.

## Uninstall

```bash
sudo apt remove darpan
rm -rf ~/.config/darpan ~/.local/state/darpan ~/.local/share/darpan   # settings, password, network state
```

Also remove the device from the Tailscale admin console.

## Repository layout

```text
PROTOCOL.md        wire protocol: the contract every client implements
MAC_PROMPT.md      design brief for the macOS client
dev-messageboard/  asynchronous coordination between contributors
linux/             host: Python daemon, C capture/NVENC encoder, browser client, packaging, tests
mac/               native macOS client (Swift)
scripts/           repository maintenance (privacy check)
dist/              build output (.deb, .dmg); not committed, attached to releases
```

Developer notes: [linux/README.md](linux/README.md), [mac/README.md](mac/README.md).

## Publishing

This repository's history, pull requests and releases contain development data (names, host and
device identifiers, e-mail addresses in commit metadata). Rewriting history does not remove it:
GitHub keeps pull-request copies of old commits. To publish:

1. Run `scripts/check-private-data.sh` until it reports nothing. It scans the working tree against
   generic patterns plus an untracked, local denylist (`.private-denylist`, one pattern per line).
2. Create a **new** repository from a snapshot of the tree (no history), committed with a
   GitHub no-reply address.
3. Rebuild the packages from that snapshot and create fresh releases; don't copy the old ones.
