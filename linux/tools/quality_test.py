#!/usr/bin/env python3
"""Video quality, measured. Paints known 2560×1440 screens on a private Xvfb (coloured code text, a
light panel with text, a gradient, saturated cards), scrolls them (20 px a frame, then a fast 60 px)
and switches to another screen. It has darpan-capture encode each picture at 12 Mbit/s (one credit
per frame, then the six refreshes after the screen settles), decodes the stream with FFmpeg's decoder
(GStreamer avdec_h264) and compares every picture with its source (PSNR). Both encoder routes run:
Vulkan Video (the default) and CUDA ("Full GPU on the Linux computer"). Vulkan's encoder searches a
smaller range for motion, so fast scrolling is where CUDA is better. Full colour (4:4:4) runs at
Higher Quality's 30 Mbit/s: 4:2:0 stops near 34.7 dB on this screen at any bitrate. The floors sit a
little under what an RTX 4090 measures.
Usage: python3 linux/tools/quality_test.py [helper]      Needs Xvfb, PIL, GStreamer's avdec_h264, NVENC."""
import ctypes, math, os, random, struct, subprocess, sys, threading, time
from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "native", "darpan-capture")
W, H, KBPS = 2560, 1440, 12000
FLOORS = {("vulkan", 20): (31.5, 33.3), ("cuda", 20): (31.5, 33.0),           # dB: scrolling, settled
          ("vulkan", 60): (28.0, 32.0), ("cuda", 60): (30.5, 32.8),
          ("vulkan 4:4:4", 20): (36.8, 38.6), ("cuda 4:4:4", 20): (36.3, 38.3)}
MONO = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15)
SANS = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 16)
COLS = [(0xE0, 0x6C, 0x75), (0x98, 0xC3, 0x79), (0x61, 0xAF, 0xEF), (0xE5, 0xC0, 0x7B), (0xC6, 0x78, 0xDD),
        (0x56, 0xB6, 0xC2), (0xAB, 0xB2, 0xBF), (0xD1, 0x9A, 0x66)]
WORDS = "def return import class self async await for while if else elif try except with lambda yield None".split()


def code_page(seed, lines=180):
    """A dark editor with coloured syntax, taller than the screen, to scroll."""
    rnd = random.Random(seed)
    img = Image.new("RGB", (1500, lines * 20 + 40), (0x28, 0x2C, 0x34))
    d = ImageDraw.Draw(img)
    for i in range(lines):
        x = 20 + 30 * rnd.randrange(0, 4)
        for _ in range(rnd.randrange(3, 10)):
            w = rnd.choice(WORDS) if rnd.random() < 0.5 else "".join(rnd.choice("abcdefghij_") for _ in range(rnd.randrange(3, 12)))
            d.text((x, 10 + 20 * i), w, font=MONO, fill=rnd.choice(COLS))
            x += 9 * (len(w) + 1)
    return img


def screen(page, scroll, seed):
    s = Image.new("RGB", (W, H), (0xF4, 0xF5, 0xF7))
    s.paste(page.crop((0, scroll, 1500, scroll + H)), (0, 0))
    d = ImageDraw.Draw(s)
    rnd = random.Random(seed)
    for i in range(44):                                         # a light panel: dark and blue text
        d.text((1530, 20 + 22 * i), " ".join(rnd.choice(WORDS) for _ in range(6)), font=SANS,
               fill=(0x1F, 0x23, 0x28) if i % 3 else (0x09, 0x69, 0xDA))
    for y in range(400):                                        # a smooth gradient
        c = int(40 + 60 * y / 400)
        d.line([(1530, 1000 + y), (2540, 1000 + y)], fill=(c, c // 2 + 20, 90 + c))
    for i in range(24):                                         # saturated cards with white labels
        x, y = 2000 + (i % 4) * 135, 20 + (i // 4) * 150
        d.rounded_rectangle([x, y, x + 120, y + 130], 12, fill=COLS[i % len(COLS)])
        d.text((x + 10, y + 55), "card %d" % i, font=SANS, fill=(255, 255, 255))
    return s


def psnr(a, b):
    st = ImageStat.Stat(ImageChops.difference(a, b))
    mse = sum(v / st.count[0] for v in st.sum2) / 3
    return 99.0 if mse == 0 else 10 * math.log10(255 ** 2 / mse)


pageA, pageB = code_page(1), code_page(2)
REFRESHES = 6


def measure(env, step, kbps=KBPS, extra=()):
    """PSNR of every decoded picture against its source, for one encoder route and scroll speed."""
    FRAMES = [screen(pageA, 0, 1)] + [screen(pageA, step * i, 1) for i in range(1, 13)] + [screen(pageB, 0, 2)]
    disp = next(":%d" % n for n in range(120, 160) if not os.path.exists("/tmp/.X11-unix/X%d" % n))
    xvfb = subprocess.Popen(["Xvfb", disp, "-screen", "0", "%dx%dx24" % (W, H), "-nolisten", "tcp", "-noreset"],
                            stderr=subprocess.DEVNULL)
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
        x.XDefaultVisual.restype = ctypes.c_void_p
        x.XDefaultVisual.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XCreateGC.restype = ctypes.c_void_p
        x.XCreateGC.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        x.XCreateImage.restype = ctypes.c_void_p
        x.XCreateImage.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_int, ctypes.c_int]
        x.XPutImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int,
                                ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]
        x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        d = x.XOpenDisplay(disp.encode())
        root, vis = x.XDefaultRootWindow(d), x.XDefaultVisual(d, 0)
        gc = x.XCreateGC(d, root, 0, None)
        keep = []

        def paint(img):
            data = img.convert("RGBX").tobytes("raw", "BGRX")
            keep.append(data)                                   # XImage points into it
            x.XPutImage(d, root, gc, x.XCreateImage(d, vis, 24, 2, 0, data, W, H, 32, W * 4), 0, 0, 0, 0, W, H)
            x.XSync(d, 0)

        paint(FRAMES[0])
        cap = subprocess.Popen([HELPER, "--display", disp, "--fps", "60", "--bitrate", str(kbps), "--credits", "0", *extra],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env=dict(os.environ, **env))
        aus, got = [], threading.Event()

        def reader():
            while True:
                h = cap.stdout.read(24)
                if len(h) < 24:
                    return
                n, flags = struct.unpack("<II", h[:8])
                data = cap.stdout.read(n)
                if not flags & 0x80000000:
                    aus.append(data)
                    got.set()
        threading.Thread(target=reader, daemon=True).start()

        def one_frame():
            got.clear()
            cap.stdin.write(b"c 1\n")
            cap.stdin.flush()
            if not got.wait(5):
                raise RuntimeError("no frame from darpan-capture")

        time.sleep(0.5)
        src = []
        for i, f in enumerate(FRAMES):
            if i:
                paint(f)
                time.sleep(0.02)
            one_frame()
            src.append(f)
            time.sleep(1 / 60)
        for _ in range(REFRESHES):
            one_frame()
            src.append(FRAMES[-1])
        cap.stdin.write(b"q\n")
        cap.stdin.flush()
        cap.wait(5)
    finally:
        if cap and cap.poll() is None:
            cap.kill()
        xvfb.terminate()                                        # not kill: it removes its socket and lock
        xvfb.wait(5)

    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst
    Gst.init(None)
    p = Gst.parse_launch("appsrc name=src format=time caps=video/x-h264,stream-format=byte-stream,alignment=au "
                         "! avdec_h264 ! videoconvert ! video/x-raw,format=RGB ! appsink name=sink sync=false")
    appsrc, sink = p.get_by_name("src"), p.get_by_name("sink")
    p.set_state(Gst.State.PLAYING)
    for i, au in enumerate(aus):
        b = Gst.Buffer.new_wrapped(au)
        b.pts = i * 16_666_667
        appsrc.emit("push-buffer", b)
    appsrc.emit("end-of-stream")
    out = []
    while (smp := sink.emit("try-pull-sample", 5 * Gst.SECOND)) is not None:
        ok, mi = smp.get_buffer().map(Gst.MapFlags.READ)
        out.append(psnr(Image.frombytes("RGB", (W, H), bytes(mi.data)), src[len(out)]))
    p.set_state(Gst.State.NULL)
    return out if len(out) == len(FRAMES) + REFRESHES else []


results = []
cases = [(api, env, step, KBPS, ()) for step in (20, 60) for api, env in (("vulkan", {}), ("cuda", {"DARPAN_NVENC_CUDA": "1"}))]
cases += [("vulkan 4:4:4", {}, 20, 30000, ("--chroma", "444")), ("cuda 4:4:4", {"DARPAN_NVENC_CUDA": "1"}, 20, 30000, ("--chroma", "444"))]
for api, env, step, kbps, extra in cases:
    ps = measure(env, step, kbps, extra)
    scroll, settled = (sum(ps[1:13]) / 12, ps[-1]) if ps else (0, 0)
    floor_scroll, floor_settled = FLOORS[(api, step)]
    passed = scroll >= floor_scroll and settled >= floor_settled
    results.append(passed)
    print("  %s %-12s %d px scroll, %d kbit/s: scrolling %.2f dB (floor %.1f), settled %.2f dB (floor %.1f)" % (
        "PASS" if passed else "FAIL", api, step, kbps, scroll, floor_scroll, settled, floor_settled))
print("\nRESULT:", "ALL PASS" if all(results) else "FAILURES")
sys.exit(0 if all(results) else 1)
