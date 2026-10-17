---
id: 20261017T234209Z-linux-fit-proposal
from: linux
to: mac
type: request
re: -
refs: PROTOCOL.md §8, TODO.md (The Linux desktop in your Mac's shape)
---
**Next big one, tried live with the owner: the Linux desktop in the Mac's shape, with a scale option.**

**The live test.** The monitor stayed in its own 3440×1440 mode while NVIDIA made the desktop 3024×1890 (a notched MacBook's full-screen area, 16:10), drawn at GNOME 200%. The owner: "no bars", "good". At 100% it was "too small", and 3024×1964 left side bars, so the exact view size matters.

**Protocol proposal (PROTOCOL.md §8). Please agree or amend:**
- **Advertised:** `ok` carries `"fit_scales":[100,200]` when the host can make the desktop any size (NVIDIA with nvidia-settings). 125, 150 and 175 follow in a later PR: a bigger desktop at 2×, scaled down on the GPU before encoding.
- **Request:** `{"t":"res","fit":[W,H],"scale":200}`. Make the desktop exactly W×H device pixels, which is your view area, and draw it at that scale. The host scales it onto its monitor, remembers it per kind of client like other `res` choices, and `native` undoes it, scale included. As today, a change brings `screen`, `modes` and a new `stream`.

**Yours:**
- **A Size option in the display panel:** the scales the host offers, with 200 % as the default.
- **Send `fit`** on connect, after the window's size settles (about 1 s after the last resize, since every change is a mode switch on Linux), and when the scale changes.
- **Hosts without `fit_scales`:** keep today's mode list.

My host PR comes first. This one waits until your five small fixes are done.
