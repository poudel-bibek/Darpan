#!/usr/bin/env python3
"""Dev tool: record what darpan-capture sends, for decoder tests on other machines (the Mac's
SelfTest). On a private 640×360 Xvfb the whole screen is repainted at 60 Hz (like a compositor), a box
moves for a second, rests for 1.5 s and moves again (reference frames with motion vectors), and
a 10×2 line between the sampled rows toggles 5 times a second (non-reference probes). Writes
<name>.h264 (Annex B), <name>.json (which pictures are IDR / non-reference, decode results) and
<name>-last.png (FFmpeg's decode of the last picture, through GStreamer's avdec_h264).
Usage: python3 linux/tools/make_fixture.py <out-dir> <name> [helper]"""
import ctypes, json, math, os, struct, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_dir, name = sys.argv[1], sys.argv[2]
helper = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, "native", "darpan-capture")
W, H = 640, 360
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

    paint(0)
    cap = subprocess.Popen([helper, "--display", disp, "--fps", "60", "--bitrate", "2000", "--credits", "8"],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    aus, infos = [], []

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
                try:
                    cap.stdin.write(b"c 1\n")                  # like the viewer's ack
                    cap.stdin.flush()
                except OSError:
                    return
    threading.Thread(target=reader, daemon=True).start()
    t0 = time.monotonic()
    while (t := time.monotonic() - t0) < 5.0:
        paint(t)
        time.sleep(1 / 60)
    time.sleep(0.8)                                            # the settle-time refresh frames
    from PIL import ImageGrab
    source = ImageGrab.grab(xdisplay=disp).convert("RGB")
    cap.stdin.write(b"q\n")
    cap.stdin.flush()
    cap.wait(5)
finally:
    if cap and cap.poll() is None:
        cap.kill()
    xvfb.kill()

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
img.save(os.path.join(out_dir, name + "-last.png"))
start = next((i for i in infos if i.get("ev") == "start"), {})
meta = {"frames": len(aus), "idr": idr, "nonref": nonref, "bytes": len(stream), "api": start.get("api"),
        "decoded": decoded, "decoder_problems": problems,
        "last_picture_psnr_db": round(10 * math.log10(255 ** 2 / mse), 1) if mse else None}
with open(os.path.join(out_dir, name + ".json"), "w") as f:
    json.dump(meta, f, indent=1)
print(json.dumps({k: v if not isinstance(v, list) or len(v) < 12 else "%d items" % len(v) for k, v in meta.items()}))
