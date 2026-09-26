# Darpan — Linux host

```text
darpan/       Python daemon (stdlib + PyGObject only): HTTP/WebSocket server, auth, sessions,
              congestion control, X11 input (XTest), cursor (XFixes), clipboard, xrandr,
              Tailscale LocalAPI client, GTK4 status window, CLI
native/       darpan-capture: C, damage-driven XShm capture → Vulkan Video (NVENC) H.264; CUDA as fallback
              (headers vendored in third_party/, so no -dev packages are needed to build)
web/          browser client (plain JS, WebCodecs), served by the daemon
packaging/    build-deb.sh, systemd user units, desktop entry, maintainer scripts
tools/        end-to-end tests and dev helpers
```

## How a frame travels

1. The X server reports damage → `darpan-capture` wakes (it sleeps in `poll()` otherwise).
2. If the daemon has granted a credit: `XShmGetImage` into a shared-memory segment. The GPU imports
   that segment (`VK_EXT_external_memory_host`), a compute shader (`rgb2nv12.comp`) turns BGRx into
   NV12, and Vulkan Video encodes it on NVENC (`vkenc.c`: ultra-low-latency tuning, quality level 2 of 7, CBR with a 4-frame
   VBV, 1 reference frame, infinite GOP, IDR on demand). That's about 40 MB of VRAM at 2560×1440.
   Without Vulkan Video, the segment is `cuMemHostRegister`-pinned, copied by DMA into a CUDA buffer
   and encoded by NVENC through CUDA, whose context alone takes about 200 MB. With a compositor most
   damage is identical pixels, so a frame whose sampled
   rows didn't change is first encoded as a non-reference P frame. If every macroblock of it is
   P_Skip, it would decode to the picture the viewer already has, and nothing is sent.
3. The access unit goes to the daemon over a pipe and out on the WebSocket with one
   scatter-gather write (TCP_NODELAY).
4. The client decodes it (WebCodecs / VideoToolbox), draws it the moment it exists, and acks.
   One credit per ack: a slow link means fewer frames, never a queue. A delay-based AIMD
   controller adapts the bitrate; after the screen settles six "refresh" frames sharpen text.

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
python3 tools/capture_exit_test.py    # darpan-capture: exits when X goes away; Vulkan, no XShm, CUDA; VRAM
python3 tools/quality_test.py        # picture quality (PSNR) of both encoder routes, scrolling and settled
```

## The login screen

`darpan login-screen on` (or the switch in the window) runs `packaging/login-screen-setup` as root
through pkexec, for the calling user only. It marks the user in `/etc/darpan/login-screen.d/`, enables
lingering, so the user's services start at boot, and sets `WaylandEnable=false` for GDM (marked, so
`off` undoes exactly that). Then:

1. At boot, `darpan-login-screen.target` (conditioned on the mark) brings up the socket and Tailscale.
   The host starts on the first connection. Until a screen exists it closes signed-in viewers with
   4004, and they retry.
2. GDM's login screen runs `login-screen-access` from its autostart, as its own user. It grants each
   marked user access with `xhost +SI:localuser:<user>`, which covers every process of that user.
   The host finds that X server by its socket's owner (`gdm`) and accepts it only if the connection's
   peer credentials say GDM's user runs it. The capture helper can't share memory with an X server run by another user, so it
   copies frames over the X connection.
3. At login, `darpan-desktop.service` restarts the host, which then finds the desktop's `DISPLAY`.
   The socket and Tailscale are `StopWhenUnneeded=`: the login-screen target keeps them up past a
   logout, while for everyone else they stop with the desktop session, as before.

## Updates

Installed hosts update through the system's updater. The package ships
`/etc/apt/sources.list.d/darpan.sources`, pointing at `apt/` on this repository's GitHub Pages site
(`https://<owner>.github.io/<repo>/`), and the public keyring `/etc/apt/keyrings/darpan-archive-keyring.gpg`
(both conffiles: `apt remove` keeps them, `purge` removes them). A release's page carries only
`darpan_amd64.deb` and `Darpan.dmg`; the update files go to the site. Make the flat APT index with

```bash
GNUPGHOME=~/.config/darpan-release/gnupg bash packaging/apt-index.sh ../dist/darpan_<ver>_amd64.deb <apt-dir>
```

and the Mac's manifest with `scripts/mac-manifest.sh` (into `<mac-dir>`). Publish the release, then
`scripts/publish-updates.sh <apt-dir> <mac-dir>` replaces the site's files, so hosts and Macs see the new
version only once its downloads exist. The private key stays on the release
machine: keep a backup of `~/.config/darpan-release`, because with a new key existing installs stop
trusting new releases until the package is reinstalled by hand.
