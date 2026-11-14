# To do

Bigger ideas that aren't scheduled yet. Want to help with one? Open an issue first.

## Connect both ways

Today the Linux computer is the one you connect **to**. Make it work in both directions, so you
can also use your Mac from Linux.

* **On the Mac:** one switch, *Allow my other computers to connect*, off by default. The first time,
  macOS asks for Screen Recording and Accessibility. Like Linux, the Mac shows its own address and
  password.
* **On Linux:** the Darpan window lists your Macs. Click one to connect.
* **No new setup:** both are already on your Tailscale network.
* **The work:** a Mac host (ScreenCaptureKit capture, VideoToolbox H.264, input, sound) that speaks
  [PROTOCOL.md](PROTOCOL.md), so a browser can connect to it right away; then a native Linux viewer.
* **Same rules:** zero work while nobody is connected, and only your devices get in.

## The Linux desktop in your Mac's shape

A 16:9 Linux screen on a 16:10 Mac screen leaves bars above and below, like every remote desktop
does. Picking a 16:10 resolution removes them but costs sharpness, and monitors often offer none
that's big enough.

* **The idea:** while you're connected, make the Linux desktop exactly the Mac window's shape at
  full sharpness (e.g. 2304×1440 on a 2560×1440 monitor), and let the NVIDIA GPU scale that
  custom-size desktop onto the monitor. Put it back when you disconnect, as resolutions are today.
* **The work:** NVIDIA's MetaModes (`ViewPortIn`/`ViewPortOut`) or xrandr `--fb` with a transform,
  tested across monitors and drivers. The physical monitor shows pillarboxes meanwhile.
* **Same rules:** nothing changes unless you choose it, and nothing runs while nobody is connected.

## Several monitors

With two monitors on the Linux computer, Darpan sends the whole X screen: both side by side in one
picture, small on the Mac, and more to capture and encode than you're looking at.

* **Pick one:** the display panel lists the Linux computer's monitors, and only the one you choose
  is captured, encoded and sent. The primary monitor by default; *All* shows them side by side as
  today.
* **Stays efficient:** changes on a monitor you aren't shown cost nothing, and switching restarts
  the stream, not the session.
* **The work:** list the monitors with xrandr, capture only the chosen one's rectangle (on the CUDA
  and the Vulkan paths), shift pointer input by its position, and apply resolution changes to it.
  The monitor list and the choice need a PROTOCOL.md change agreed with the Mac side.

## Thin lines at 125–175 %

At these sizes the Linux desktop is drawn bigger and shrunk for the stream. The shrink weighs pixels
unevenly, so a thin line, such as the text caret, is strong at some positions and nearly gone at
others. At 125 % a 1-pixel line keeps between 28 % and 93 % of its darkness.

* **The goal:** a thin line looks the same wherever it sits, and text stays as sharp as it is today.
* **The idea:** grab the desktop at full size and shrink it in Darpan's own GPU step with exact
  weights, instead of the X server's filter. Measured on an RTX 4090: the full-size grab is no slower
  (4.7 ms against 6.2 ms).
* **Not the way:** a two-step shrink in the X server is even, but softer (0.9 dB) and takes about
  110 MB of GPU memory.
* **The work:** the shader and the capture on the Vulkan path, the CUDA path too, and a thin-line
  check in `quality_test.py`.
