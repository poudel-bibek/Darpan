Build-time headers only (nothing here is shipped), vendored so `make` works without -dev packages:

* `include/X11/` — Xlib, XShm, Xdamage, Xfixes, XTest headers from Ubuntu 24.04 `libx11-dev`,
  `x11proto-dev`, `libxext-dev`, `libxdamage-dev`, `libxfixes-dev`, `libxtst-dev` (MIT/X11 licenses).
* `include/ffnvcodec/` — NVIDIA Video Codec SDK headers via FFmpeg's nv-codec-headers 12.1.14
  (`libffmpeg-nvenc-dev`), MIT license. NVENC/CUDA are loaded at runtime with dlopen.
