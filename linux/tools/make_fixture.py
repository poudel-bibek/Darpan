#!/usr/bin/env python3
"""Dev tool: record what darpan-capture sends, for decoder tests on other machines (the Mac's
SelfTest). On a private 640×360 Xvfb the whole screen is repainted at 60 Hz (like a compositor), a box
moves for a second, rests for 1.5 s and moves again (frames with motion vectors), and a 10×2 line
toggles 5 times a second (small changes; the identical repaints between them aren't sent). Writes
<name>.h264 (Annex B), <name>.json (which pictures are IDR / non-reference, decode results) and
<name>-last.png (FFmpeg's decode of the last picture, through GStreamer's avdec_h264; with --444 its
top-left 640×360).
With --444: six pictures of 2560×1440 coloured code in full colour (High 4:4:4 Predictive, CAVLC)
at Higher Quality's 30 Mbit/s: the key frame, two 20 px scroll steps and three refreshes.
Usage: python3 linux/tools/make_fixture.py [--444] <out-dir> <name> [helper]"""
import ctypes, json, math, os, struct, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FULL = "--444" in sys.argv
argv = [a for a in sys.argv[1:] if a != "--444"]
out_dir, name = argv[0], argv[1]
helper = argv[2] if len(argv) > 2 else os.path.join(ROOT, "native", "darpan-capture")
W, H = (2560, 1440) if FULL else (640, 360)
disp = next(":%d" % n for n in range(80, 120) if not os.path.exists("/tmp/.X11-unix/X%d" % n))
xvfb = subprocess.Popen(["Xvfb", disp, "-screen", "0", "%dx%dx24" % (W, H), "-nolisten", "tcp", "-noreset"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
cap = None
try:
    for _ in range(100):
        if os.path.exists("/tmp/.X11-unix/X" + disp[1:]):
            break
        time.sleep(0.05)
    x = ctypes.CDLL("libX11.so.6")
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XDefaultRootWindow.restype = ctypes.c_ulong
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XCreateGC.restype = ctypes.c_void_p
    x.XCreateGC.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
    x.XSetForeground.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
    x.XFillRectangle.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                 ctypes.c_uint, ctypes.c_uint]
    x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    d = x.XOpenDisplay(disp.encode())
    root = x.XDefaultRootWindow(d)
    gc = x.XCreateGC(d, root, 0, None)

    def paint(t):
        x.XSetForeground(d, gc, 0x303848)
        x.XFillRectangle(d, root, gc, 0, 0, W, H)              # full re-damage, same pixels
        bx = int(40 + 200 * (min(t, 1.0) + max(0.0, min(t, 3.5) - 2.5)))   # moves in [0, 1) and [2.5, 3.5)
        x.XSetForeground(d, gc, 0xd04030)
        x.XFillRectangle(d, root, gc, bx, 150 + int(30 * math.sin(bx / 40)), 48, 48)
        x.XSetForeground(d, gc, 0x40e060 if int(t * 5) % 2 else 0x303848)
        x.XFillRectangle(d, root, gc, 300, 45, 10, 2)          # rows 45-46: between the sampled rows
        x.XSync(d, 0)

    if FULL:                                                   # coloured code, drawn the same every time
        from PIL import Image, ImageDraw, ImageFont
        mono = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15)
        cols = [(0xE0, 0x6C, 0x75), (0x98, 0xC3, 0x79), (0x61, 0xAF, 0xEF), (0xE5, 0xC0, 0x7B), (0xC6, 0x78, 0xDD),
                (0x56, 0xB6, 0xC2)]
        page = Image.new("RGB", (W, H + 60), (0x28, 0x2C, 0x34))
        dr = ImageDraw.Draw(page)
        for i in range((H + 60) // 20):                        # two columns of code-like lines
            for x0 in (20, 1300):
                n = (i * 7 + x0) % 5
                dr.text((x0 + 36 * (i % 4), 5 + 20 * i), "def f%d(self, x): return {'colour': %d}" % (i, i * 7) + " + x" * n,
                        font=mono, fill=cols[(i + n) % len(cols)])
        x.XDefaultVisual.restype = ctypes.c_void_p
        x.XDefaultVisual.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XCreateImage.restype = ctypes.c_void_p
        x.XCreateImage.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_int, ctypes.c_int]
        x.XPutImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p] + [ctypes.c_int] * 4 + [ctypes.c_uint] * 2
        keep = []

        def paint(t):                                          # t: how far it has scrolled, in px
            data = page.crop((0, int(t), W, int(t) + H)).convert("RGBX").tobytes("raw", "BGRX")
            keep.append(data)
            x.XPutImage(d, root, gc, x.XCreateImage(d, x.XDefaultVisual(d, 0), 24, 2, 0, data, W, H, 32, W * 4),
                        0, 0, 0, 0, W, H)
            x.XSync(d, 0)
    paint(0)
    cap = subprocess.Popen([helper, "--display", disp, "--fps", "60"] +
                           (["--bitrate", "30000", "--credits", "0", "--chroma", "444"] if FULL else
                            ["--bitrate", "2000", "--credits", "8"]),
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    aus, infos, got = [], [], threading.Event()

    def reader():
        while True:
            hdr = cap.stdout.read(24)
            if len(hdr) < 24:
                return
            n, flags = struct.unpack("<II", hdr[:8])
            data = cap.stdout.read(n)
            if flags & 0x80000000:
                infos.append(json.loads(data))
            else:
                aus.append(data)
                got.set()
                if FULL:
                    continue                                   # one credit per picture, below
                try:
                    cap.stdin.write(b"c 1\n")                  # like the viewer's ack
                    cap.stdin.flush()
                except OSError:
                    return
    threading.Thread(target=reader, daemon=True).start()
    if FULL:
        time.sleep(0.5)
        for scroll in (0, 20, 40, None, None, None):           # the key frame, two scroll steps, refreshes
            if scroll:
                paint(scroll)
                time.sleep(0.02)
            got.clear()
            cap.stdin.write(b"c 1\n")
            cap.stdin.flush()
            got.wait(5)
    else:
        t0 = time.monotonic()
        while (t := time.monotonic() - t0) < 5.0:
            paint(t)
            time.sleep(1 / 60)
        time.sleep(0.8)                                        # the settle-time refresh frames
    from PIL import ImageGrab
    source = ImageGrab.grab(xdisplay=disp).convert("RGB")
    cap.stdin.write(b"q\n")
    cap.stdin.flush()
    cap.wait(5)
finally:
    if cap and cap.poll() is None:
        cap.kill()
    xvfb.terminate()                                           # not kill: it removes its socket and lock
    xvfb.wait(5)

stream = b"".join(aus)
idr, nonref = [], []
for i, au in enumerate(aus):
    for part in au.split(b"\x00\x00\x01")[1:]:
        t = part[0] & 0x1F
        if t in (1, 5):
            if t == 5:
                idr.append(i)
            if not part[0] >> 5 & 3:
                nonref.append(i)
            break

sys.path.insert(0, os.path.join(ROOT, "tools"))
import gi  # noqa: E402
gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402
Gst.init(None)
p = Gst.parse_launch("appsrc name=src format=time caps=video/x-h264,stream-format=byte-stream,alignment=au "
                     "! avdec_h264 ! videoconvert ! video/x-raw,format=RGB ! appsink name=sink sync=false")
src, sink = p.get_by_name("src"), p.get_by_name("sink")
p.set_state(Gst.State.PLAYING)
for i, au in enumerate(aus):
    b = Gst.Buffer.new_wrapped(au)
    b.pts = i * 16_666_667
    src.emit("push-buffer", b)
src.emit("end-of-stream")
decoded, last = 0, None
while (s := sink.emit("try-pull-sample", 3 * Gst.SECOND)) is not None:
    decoded, last = decoded + 1, s
problems = []
bus = p.get_bus()
while (m := bus.pop_filtered(Gst.MessageType.WARNING | Gst.MessageType.ERROR)) is not None:
    problems.append(str(m.parse_warning()[0] if m.type == Gst.MessageType.WARNING else m.parse_error()[0]))
p.set_state(Gst.State.NULL)
ok, mi = last.get_buffer().map(Gst.MapFlags.READ)
from PIL import Image  # noqa: E402
img = Image.frombytes("RGB", (W, H), bytes(mi.data))
mse = sum((a - b) ** 2 for a, b in zip(img.tobytes(), source.tobytes())) / (W * H * 3)

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, name + ".h264"), "wb") as f:
    f.write(stream)
(img.crop((0, 0, 640, 360)) if FULL else img).save(os.path.join(out_dir, name + "-last.png"))   # 4:4:4: the top left
start = next((i for i in infos if i.get("ev") == "start"), {})
meta = {"frames": len(aus), "idr": idr, "nonref": nonref, "bytes": len(stream), "api": start.get("api"),
        "chroma": start.get("chroma", 420),
        "decoded": decoded, "decoder_problems": problems,
        "last_picture_psnr_db": round(10 * math.log10(255 ** 2 / mse), 1) if mse else None}
with open(os.path.join(out_dir, name + ".json"), "w") as f:
    json.dump(meta, f, indent=1)
print(json.dumps({k: v if not isinstance(v, list) or len(v) < 12 else "%d items" % len(v) for k, v in meta.items()}))
