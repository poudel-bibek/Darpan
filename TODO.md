# To do

Bigger ideas that aren't scheduled yet. Want to help with one? Open an issue first.

## Connect both ways

Today the Linux computer is the one you connect **to**. Make it work in both directions, so you
can also use your Mac from Linux.

* **On the Mac:** one switch, *Allow my other computers to connect*, off by default. The first time,
  macOS asks for Screen Recording and Accessibility. Same address and password as on Linux.
* **On Linux:** the Darpan window lists your Macs. Click one to connect.
* **No new setup:** both are already on your Tailscale network.
* **The work:** a Mac host (ScreenCaptureKit capture, VideoToolbox H.264, input, sound) that speaks
  [PROTOCOL.md](PROTOCOL.md), so a browser can connect to it right away; then a native Linux viewer.
* **Same rules:** zero work while nobody is connected, and only your devices get in.
