# Darpan — Linux host

```text
darpan/       Python daemon (stdlib + PyGObject only): HTTP/WebSocket server, auth, sessions,
              congestion control, X11 input (XTest), cursor (XFixes), clipboard, xrandr,
              Tailscale LocalAPI client, GTK4 status window, CLI
native/       darpan-capture: C, damage-driven XShm capture → pinned DMA → CUDA → NVENC H.264
              (headers vendored in third_party/, so no -dev packages are needed to build)
web/          browser client (plain JS, WebCodecs), served by the daemon
packaging/    build-deb.sh, systemd user units, desktop entry, maintainer scripts
tools/        end-to-end tests and dev helpers
```

## How a frame travels

1. The X server reports damage → `darpan-capture` wakes (it sleeps in `poll()` otherwise).
2. If the daemon has granted a credit: `XShmGetImage` into a shared-memory segment that is
   `cuMemHostRegister`-pinned, `cuMemcpy2D` (DMA) into a CUDA buffer, NVENC encodes BGRx directly
   (P3 preset, ultra-low-latency tuning, CBR with a 4-frame VBV, 1 reference frame, infinite GOP,
   IDR on demand). With a compositor most damage is identical pixels, so a frame whose sampled
   rows didn't change is first encoded as a non-reference P frame. If every macroblock of it is
   P_Skip, it would decode to the picture the viewer already has, and nothing is sent.
3. The access unit goes to the daemon over a pipe and out on the WebSocket with one
   scatter-gather write (TCP_NODELAY).
4. The client decodes it (WebCodecs / VideoToolbox), draws it the moment it exists, and acks.
   One credit per ack: a slow link means fewer frames, never a queue. A delay-based AIMD
   controller adapts the bitrate; after the screen settles two "refresh" frames sharpen text.

## Build & run from source

```bash
make -C native                       # → native/darpan-capture
python3 -m darpan serve -v            # needs DISPLAY; web client at http://127.0.0.1:47470
bash packaging/build-deb.sh           # → ../dist/darpan_<ver>_amd64.deb
```

## Tests (never touch the real desktop — they run on a private Xvfb display)

```bash
python3 tools/test_host.py            # 20 protocol/input/clipboard/upload/latency checks
node tools/webclient_test.mjs         # 17 checks: headless Chrome ↔ real host
python3 tools/apt_test.py             # the release's APT index, as installed hosts use it
```

## Updates

Installed hosts update through the system's updater. The package ships
`/etc/apt/sources.list.d/darpan.sources`, pointing at `releases/latest/download/` of this repository, and
the public keyring `/etc/apt/keyrings/darpan-archive-keyring.gpg` (both conffiles: `apt remove` keeps
them, `purge` removes them). So each release carries, next to
`darpan_amd64.deb`, a flat APT index made by

```bash
GNUPGHOME=~/.config/darpan-release/gnupg bash packaging/apt-index.sh ../dist/darpan_<ver>_amd64.deb <dir>
```

Upload `Packages` and `InRelease` from `<dir>` with the .deb to the **draft** release, then publish it,
so `latest` switches to all three at once. The private key stays on the release
machine: keep a backup of `~/.config/darpan-release`, because with a new key existing installs stop
trusting new releases until the package is reinstalled by hand.
