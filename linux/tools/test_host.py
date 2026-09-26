#!/usr/bin/env python3
"""End-to-end test of the host against an isolated Xvfb display. Never touches the real
desktop. Starts: Xvfb, a probe window (logs input + repaints on key press), the host
daemon with throw-away XDG dirs; then speaks PROTOCOL.md as a client and checks results.

    python3 tools/test_host.py [--display :99] [--port 47490]
"""
import argparse
import asyncio
import base64
import ctypes
import hashlib
import hmac
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE_APP = r'''
import ctypes, sys, time
x = ctypes.CDLL("libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p; x.XOpenDisplay.argtypes = [ctypes.c_char_p]
d = x.XOpenDisplay(None)
x.XDefaultScreen.argtypes = [ctypes.c_void_p]; s = x.XDefaultScreen(d)
x.XRootWindow.restype = ctypes.c_ulong; x.XRootWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
x.XCreateSimpleWindow.restype = ctypes.c_ulong
x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + [ctypes.c_int]*2 + [ctypes.c_uint]*3 + [ctypes.c_ulong]*2
W, H = int(sys.argv[1]), int(sys.argv[2])
win = x.XCreateSimpleWindow(d, x.XRootWindow(d, s), 0, 0, W, H, 0, 0, 0x202020)
x.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
x.XSelectInput(d, win, (1<<0)|(1<<1)|(1<<2)|(1<<3)|(1<<6)|(1<<15)|(1<<17))
x.XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]; x.XMapWindow(d, win)
x.XDefaultGC.restype = ctypes.c_void_p; x.XDefaultGC.argtypes = [ctypes.c_void_p, ctypes.c_int]
gc = x.XDefaultGC(d, s)
x.XSetForeground.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
x.XFillRectangle.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]
x.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
x.XFlush.argtypes = [ctypes.c_void_p]
x.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
x.XLookupKeysym.restype = ctypes.c_ulong; x.XLookupKeysym.argtypes = [ctypes.c_void_p, ctypes.c_int]
x.XLookupString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
x.XRefreshKeyboardMapping.argtypes = [ctypes.c_void_p]
# Colour bars for the colour-accuracy check (left half), a key-press flash area (right half)
BARS = [0xff0000, 0x00ff00, 0x0000ff, 0xffffff, 0x808080, 0x300a24, 0xffff00, 0x00ffff]
def paint(flash):
    bw = (W // 2) // len(BARS)
    for i, c in enumerate(BARS):
        x.XSetForeground(d, gc, c); x.XFillRectangle(d, win, gc, i * bw, 0, bw, H)
    x.XSetForeground(d, gc, flash); x.XFillRectangle(d, win, gc, W // 2, 0, W - W // 2, H)
    x.XFlush(d)
ev = (ctypes.c_long * 24)()
colors = [0x202020, 0xe0e0e0]; n = 0
while True:
    x.XNextEvent(d, ev)
    t = ev[0] & 0x7f
    if t == 12:   # Expose
        paint(colors[n % 2])
    elif t == 19:  # MapNotify
        x.XSetInputFocus(d, win, 1, 0); x.XFlush(d)
    elif t == 2:   # KeyPress
        buf = ctypes.create_string_buffer(16)
        k = x.XLookupString(ctypes.byref(ev), buf, 16, None, None)
        kc = ctypes.cast(ctypes.byref(ev), ctypes.POINTER(ctypes.c_uint * 22)).contents[21]
        n += 1; paint(colors[n % 2])
        print("KEY press keycode=%d text=%r" % (kc, buf.raw[:k].decode("latin-1")), flush=True)
    elif t == 3:
        kc = ctypes.cast(ctypes.byref(ev), ctypes.POINTER(ctypes.c_uint * 22)).contents[21]
        print("KEY release keycode=%d" % kc, flush=True)
    elif t in (4, 5):
        b = ctypes.cast(ctypes.byref(ev), ctypes.POINTER(ctypes.c_uint * 22)).contents[21]
        print("BUTTON %s %d" % ("press" if t == 4 else "release", b), flush=True)
    elif t == 34:  # MappingNotify: refresh the keymap, as every real toolkit does
        x.XRefreshKeyboardMapping(ctypes.byref(ev))
    elif t == 6:
        xy = ctypes.cast(ctypes.byref(ev), ctypes.POINTER(ctypes.c_int * 24)).contents
        print("MOTION %d %d" % (xy[16], xy[17]), flush=True)
'''


class WS:
    """Minimal WebSocket client (masking, text/binary)."""

    def __init__(self, r, w):
        self.r, self.w = r, w
        self.answer_pings = True     # False: a peer whose TCP is alive but whose app is gone

    @classmethod
    async def connect(cls, host, port, path="/ws"):
        r, w = await asyncio.open_connection(host, port)
        key = base64.b64encode(os.urandom(16)).decode()
        w.write(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                 "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key)).encode())
        head = await r.readuntil(b"\r\n\r\n")
        assert head.startswith(b"HTTP/1.1 101"), head
        return cls(r, w)

    def send(self, obj=None, binary=None):
        data, op = (binary, 2) if binary is not None else (json.dumps(obj).encode(), 1)
        self.frame(op, data)

    def frame(self, op, data):
        mask = os.urandom(4)
        n = len(data)
        hdr = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else (bytes([0xFE]) + struct.pack(">H", n) if n < 65536 else bytes([0xFF]) + struct.pack(">Q", n)))
        m = int.from_bytes((mask * (n // 4 + 1))[:n], "little")
        payload = (int.from_bytes(data, "little") ^ m).to_bytes(n, "little") if n else b""
        self.w.write(hdr + mask + payload)

    async def recv(self):
        while True:
            b0, b1 = await self.r.readexactly(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", await self.r.readexactly(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", await self.r.readexactly(8))[0]
            data = await self.r.readexactly(n)
            op = b0 & 0x0F
            if op == 9:              # ping
                if self.answer_pings:
                    self.frame(10, data)
                continue
            if op != 10:             # pong: nothing to do
                break
        if op == 8:
            return ("close", struct.unpack(">H", data[:2])[0] if len(data) >= 2 else None)
        if op == 1:
            return ("text", json.loads(data))
        return ("binary", data)


def proof_for(password, hello):
    salt = base64.b64decode(hello["kdf"]["salt"])
    key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, hello["kdf"]["iter"], 32)
    return base64.b64encode(hmac.new(key, b"darpan-auth-v1" + base64.b64decode(hello["nonce"]), hashlib.sha256).digest()).decode()


def decode_frames(frames, png_path):
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst
    Gst.init(None)
    p = Gst.parse_launch("appsrc name=src format=time caps=video/x-h264,stream-format=byte-stream,alignment=au "
                         "! avdec_h264 ! videoconvert ! video/x-raw,format=RGB ! appsink name=sink sync=false")
    src, sink = p.get_by_name("src"), p.get_by_name("sink")
    p.set_state(Gst.State.PLAYING)
    for i, au in enumerate(frames):
        b = Gst.Buffer.new_wrapped(au)
        b.pts = i * 16_666_667
        src.emit("push-buffer", b)
    src.emit("end-of-stream")
    last = None
    while True:
        s = sink.emit("try-pull-sample", 3 * Gst.SECOND)
        if s is None:
            break
        last = s
    p.set_state(Gst.State.NULL)
    caps = last.get_caps().get_structure(0)
    w, h = caps.get_value("width"), caps.get_value("height")
    ok, mi = last.get_buffer().map(Gst.MapFlags.READ)
    from PIL import Image
    img = Image.frombytes("RGB", (w, h), bytes(mi.data))
    img.save(png_path)
    return img


async def run(args, tmp, probe_log):
    results = []

    def ok(name, cond, detail=""):
        results.append((name, bool(cond)))
        print("  %s %-34s %s" % ("PASS" if cond else "FAIL", name, detail), flush=True)

    pw = open(os.path.join(tmp, "config", "darpan", "password.txt")).read().strip()

    async def pump(ws, seconds, want=None):
        """Read for `seconds`, acking every frame. Returns (frames, first text msg of type `want`)."""
        n, found = 0, None
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                kind, m = await asyncio.wait_for(ws.recv(), max(0.01, end - time.monotonic()))
            except asyncio.TimeoutError:
                break
            if kind == "binary":
                n += 1
                _, _, sid, seq, _ = struct.unpack(">BBHIQ", m[:16])
                ws.send({"t": "ack", "id": sid, "n": seq})
            elif kind == "text" and want and m.get("t") == want and found is None:
                found = m
                if want != "*":
                    break
        return n, found

    # wrong password must be denied
    ws = await WS.connect("127.0.0.1", args.port)
    kind, hello = await ws.recv()
    ws.send({"t": "auth", "proof": proof_for("wrong-password", hello), "client": "test"})
    kind, m = await ws.recv()
    ok("wrong password denied", kind == "text" and m.get("t") == "denied" and m.get("reason") == "password", str(m))

    ws = await WS.connect("127.0.0.1", args.port)
    kind, hello = await ws.recv()
    ok("hello", hello.get("t") == "hello" and hello["kdf"]["iter"] >= 100000)
    ws.send({"t": "auth", "proof": proof_for(pw, hello), "client": "test_host.py"})
    msgs = {}
    t_start = None
    frames, keyframes, sizes, arrivals = [], 0, [], []
    stream = None
    seen_cursor = False
    pong = None
    end = time.monotonic() + 3
    while time.monotonic() < end:
        try:
            kind, m = await asyncio.wait_for(ws.recv(), 0.5)
        except asyncio.TimeoutError:
            continue
        if kind == "text":
            msgs.setdefault(m["t"], m)
            if m["t"] == "ok":
                ok("authenticated", True, "screen %sx%s enc=%s" % (m["screen"]["w"], m["screen"]["h"], m.get("enc")))
                t_start = time.monotonic()
                ws.send({"t": "start", "codec": "h264", "fps": 60, "bitrate": 0})
                ws.send({"t": "ping", "c": time.time() * 1000})
            elif m["t"] == "stream":
                stream = m
            elif m["t"] == "cur":
                seen_cursor = True
            elif m["t"] == "pong":
                pong = m
        elif kind == "binary":
            kind_b, flags, sid, seq, ts = struct.unpack(">BBHIQ", m[:16])
            if not frames:
                ok("first frame latency", True, "%.0f ms from start (incl. encoder init)" % ((time.monotonic() - t_start) * 1000))
            frames.append(m[16:])
            keyframes += flags & 1
            sizes.append(len(m) - 16)
            ws.send({"t": "ack", "id": sid, "n": seq})
            if len(frames) >= 3:
                break
    ok("stream announced", stream and stream["w"] > 0, str(stream))
    ok("first frame is key frame", frames and frames and keyframes >= 1, "sizes %s" % sizes[:5])
    ok("pong", pong is not None)
    ok("modes (xrandr)", "modes" in msgs, str(msgs.get("modes", ""))[:80])
    ok("clipboard snapshot always sent", msgs.get("clip", {}).get("text") == "", repr(msgs.get("clip")))

    # decode + colour accuracy on the bars
    img = decode_frames(frames, os.path.join(tmp, "frame.png"))
    W, H = img.size
    bars = [0xff0000, 0x00ff00, 0x0000ff, 0xffffff, 0x808080, 0x300a24, 0xffff00, 0x00ffff]
    bw = (args.probe_w // 2) // len(bars)
    worst = 0
    for i, c in enumerate(bars):
        want = ((c >> 16) & 255, (c >> 8) & 255, c & 255)
        got = img.getpixel((i * bw + bw // 2, H // 2))
        worst = max(worst, max(abs(a - b) for a, b in zip(want, got)))
    ok("colour accuracy", worst <= 6, "worst channel error %d/255 (saved %s)" % (worst, os.path.join(tmp, "frame.png")))

    # input: move, click, keys → probe app log
    def log_lines():
        with open(probe_log) as f:
            return f.read().splitlines()

    ws.send({"t": "mm", "x": 100, "y": 120})
    ws.send({"t": "mb", "b": 0, "d": True})
    ws.send({"t": "mb", "b": 0, "d": False})
    ws.send({"t": "wh", "dx": 0, "dy": 240})
    await pump(ws, 0.3)
    lines = log_lines()
    ok("pointer motion", any(l == "MOTION 100 120" for l in lines), [l for l in lines if l.startswith("MOTION")][-1:])
    ok("left click", "BUTTON press 1" in lines and "BUTTON release 1" in lines)
    ok("wheel 2 notches down", lines.count("BUTTON press 5") == 2)

    # key-to-frame latency: every key press repaints half the window
    lat = []
    for i in range(10):
        # drain anything pending
        while True:
            try:
                kind, m = await asyncio.wait_for(ws.recv(), 0.05)
                if kind == "binary":
                    _, _, sid, seq, _ = struct.unpack(">BBHIQ", m[:16])
                    ws.send({"t": "ack", "id": sid, "n": seq})
            except asyncio.TimeoutError:
                break
        t0 = time.monotonic()
        ws.send({"t": "key", "c": "KeyA", "d": True})
        while True:
            kind, m = await asyncio.wait_for(ws.recv(), 2)
            if kind == "binary":
                _, flags, sid, seq, _ = struct.unpack(">BBHIQ", m[:16])
                ws.send({"t": "ack", "id": sid, "n": seq})
                if not flags & 2:
                    lat.append((time.monotonic() - t0) * 1000)
                    break
        ws.send({"t": "key", "c": "KeyA", "d": False})
        await asyncio.sleep(0.15)
    lat.sort()
    ok("key → new frame (host side)", lat and lat[len(lat) // 2] < 30,
       "median %.1f ms, min %.1f, max %.1f (inject+render+capture+encode+send)" % (lat[len(lat) // 2], lat[0], lat[-1]))
    lines = log_lines()
    ok("key text 'a'", any("text='a'" in l for l in lines))

    # shifted text through the typing path, including a non-layout character
    ws.send({"t": "txt", "s": "Hi✓"})
    await pump(ws, 0.5)
    lines = log_lines()
    typed = [l for l in lines if l.startswith("KEY press")]
    ok("txt typing", any("text='H'" in l for l in typed) and any("text='i'" in l for l in typed), typed[-4:])

    # > 8 distinct non-layout characters: every spare keycode gets reused along the way
    greek = "αβγδεζηθικλμα"
    mark = len(log_lines())
    ws.send({"t": "txt", "s": greek})
    await pump(ws, 1.0)
    typed = "".join(l.split("text=", 1)[1][1:-1].encode("latin-1").decode("utf-8", "replace")
                    for l in log_lines()[mark:] if l.startswith("KEY press") and "text=''" not in l)
    ok("typing reuses spare keycodes safely", typed == greek, repr(typed))

    # repeat: down, down, down, up  → three presses delivered
    before = sum(1 for l in log_lines() if "KEY press" in l)
    for _ in range(3):
        ws.send({"t": "key", "c": "KeyB", "d": True})
    ws.send({"t": "key", "c": "KeyB", "d": False})
    await pump(ws, 0.3)
    after = sum(1 for l in log_lines() if "KEY press" in l)
    ok("client-driven key repeat", after - before == 3, "%d presses" % (after - before))

    # clipboard client → host
    ws.send({"t": "clip", "text": "hello from test ✓"})
    await pump(ws, 0.5)
    out = subprocess.run(["xclip", "-o", "-selection", "clipboard"], env=dict(os.environ, DISPLAY=args.display),
                         capture_output=True, text=True, timeout=3).stdout
    ok("clipboard client→host", out == "hello from test ✓", repr(out))

    # paste ordering: a clip must be applied before any later message (e.g. the paste key)
    ws.send({"t": "clip", "text": "ordered paste 7"})
    ws.send({"t": "ping", "c": 1})
    _, pong2 = await pump(ws, 3, want="pong")
    out2 = subprocess.run(["xclip", "-o", "-selection", "clipboard"], env=dict(os.environ, DISPLAY=args.display),
                          capture_output=True, text=True, timeout=3).stdout
    ok("clip applied before next message", pong2 is not None and out2 == "ordered paste 7", repr(out2))

    # clipboard host → client
    subprocess.run(["xclip", "-i", "-selection", "clipboard"], input="from host 42", text=True,
                   env=dict(os.environ, DISPLAY=args.display), timeout=3)
    _, m = await pump(ws, 2, want="clip")
    got = m and m["text"]
    ok("clipboard host→client", got == "from host 42", repr(got))

    # file upload
    payload = os.urandom(700_000)
    ws.send({"t": "fput", "id": 7, "name": "../evil/../test.bin", "size": len(payload)})
    for off in range(0, len(payload), 256 * 1024):
        ws.send(binary=struct.pack(">BI", 2, 7) + payload[off:off + 256 * 1024])
    path = None
    end = time.monotonic() + 3
    while time.monotonic() < end and not path:
        kind, m = await asyncio.wait_for(ws.recv(), 2)
        if kind == "text" and m["t"] == "fdone":
            path = m["path"]
        elif kind == "binary":
            _, _, sid, seq, _ = struct.unpack(">BBHIQ", m[:16])
            ws.send({"t": "ack", "id": sid, "n": seq})
    ok("file upload (path sanitised)", path and os.path.basename(path) == "test.bin" and open(path, "rb").read() == payload, path)

    # idle: no damage → no frames (after the quality-refresh frames of the last change)
    await pump(ws, 1.0)
    n, _ = await pump(ws, 1.5)
    ok("static screen sends nothing", n == 0, "%d frames in 1.5 s" % n)

    # kf twice within a second: the second is deferred, not dropped
    await pump(ws, 0.8)
    ws.send({"t": "kf"})
    await asyncio.sleep(0.2)
    ws.send({"t": "kf"})
    keys, end = 0, time.monotonic() + 2.0
    while time.monotonic() < end:
        try:
            kind, m = await asyncio.wait_for(ws.recv(), 0.3)
        except asyncio.TimeoutError:
            continue
        if kind == "binary":
            _, flags, sid, seq, _ = struct.unpack(">BBHIQ", m[:16])
            ws.send({"t": "ack", "id": sid, "n": seq})
            keys += flags & 1
    ok("key-frame requests coalesce, never drop", keys >= 2, "%d key frames" % keys)

    # a long non-ASCII name (> 255 bytes) must save cleanly and leave no temp file behind
    long_name = "日本語のファイル" * 20 + ".txt"
    ws.send({"t": "fput", "id": 9, "name": long_name, "size": 5})
    ws.send(binary=struct.pack(">BI", 2, 9) + b"hello")
    _, done = await pump(ws, 3, want="fdone")
    dl = os.path.join(tmp, "Downloads", "Darpan")
    leftovers = [f for f in os.listdir(dl) if f.endswith(".part")]
    ok("long non-ASCII upload name", done and os.path.exists(done["path"]) and not leftovers
       and len(os.path.basename(done["path"]).encode()) <= 255, (done or {}).get("path", "")[-40:])

    def capture_pids():
        r = subprocess.run(["pgrep", "-f", "darpan-capture .*--display %s" % args.display], capture_output=True, text=True)
        return [int(p) for p in r.stdout.split()]

    ws.send({"t": "stop"})
    await pump(ws, 0.5)
    for p in capture_pids():
        os.kill(p, 9)                     # encoder dies while the viewer is hidden
    await pump(ws, 3)
    ok("paused viewer: encoder stays down", not capture_pids(), "pids %s" % capture_pids())
    ws.send({"t": "start", "codec": "h264", "fps": 60, "bitrate": 0})
    got_stream, frames2 = None, 0
    end = time.monotonic() + 4
    while time.monotonic() < end and not frames2:
        try:
            kind, m = await asyncio.wait_for(ws.recv(), 0.5)
        except asyncio.TimeoutError:
            continue
        if kind == "text" and m["t"] == "stream":
            got_stream = m
        elif kind == "binary":
            _, flags, sid, seq, _ = struct.unpack(">BBHIQ", m[:16])
            ws.send({"t": "ack", "id": sid, "n": seq})
            frames2 += flags & 1
    ok("start after pause brings it back", got_stream is not None and frames2 >= 1 and len(capture_pids()) == 1,
       "stream %s, key frames %d" % (got_stream and got_stream["id"], frames2))

    # start/stop/start in one burst must leave exactly one encoder
    for t in ("start", "stop", "start"):
        ws.send({"t": t, "codec": "h264", "fps": 60, "bitrate": 0})
    await pump(ws, 2.5)
    ok("start/stop/start burst: one encoder", len(capture_pids()) == 1, "pids %s" % capture_pids())

    # Origin: null (sandboxed iframe / data: URL) must be refused
    r, w = await asyncio.open_connection("127.0.0.1", args.port)
    w.write(("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
             "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: null\r\n\r\n" % args.port).encode())
    line = (await r.readline()).decode().strip()
    w.close()
    ok("Origin: null refused", " 403 " in line, line)

    # liveness: a peer that stops answering pings is dropped; one that answers is kept, even idle
    async def session(answer=True):
        c = await WS.connect("127.0.0.1", args.port)
        c.answer_pings = answer
        _, h = await c.recv()
        c.send({"t": "auth", "proof": proof_for(pw, h), "client": "test_host.py"})
        while (await c.recv())[1].get("t") != "ok":
            pass
        return c

    async def gone(c, seconds):
        """True once the host closes or drops c within `seconds` (reading drains what's queued)."""
        end = time.monotonic() + seconds
        try:
            while time.monotonic() < end:
                kind, _ = await asyncio.wait_for(c.recv(), max(0.01, end - time.monotonic()))
                if kind == "close":
                    return True
        except (asyncio.IncompleteReadError, ConnectionError):
            return True
        except asyncio.TimeoutError:
            pass
        return False

    dead = await session(answer=False)
    live = await session()
    t0 = time.monotonic()
    await asyncio.gather(pump(live, 8), pump(ws, 8))   # dead reads nothing meanwhile: no pongs
    live_ok = not await gone(live, 0.2)
    ok("silent peer dropped", await gone(dead, 1), "after %.0f s; host log: %s" % (time.monotonic() - t0,
       "no reply" in open(os.path.join(tmp, "host.log")).read()))
    ok("answering idle peer kept", live_ok)

    # watchdog: a peer that answers pings but never acks gets back-off resyncs, not one every 3 s
    live.send({"t": "start", "codec": "h264", "fps": 60, "bitrate": 0})
    log_path = os.path.join(tmp, "host.log")
    before = open(log_path).read().count("ack watchdog")

    async def drain(c):                        # reads (answering pings) but never acks
        try:
            while True:
                await c.recv()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass

    reader = asyncio.ensure_future(drain(live))
    end = time.monotonic() + 16
    while time.monotonic() < end:              # keep the screen changing
        ws.send({"t": "key", "c": "KeyZ", "d": True})
        ws.send({"t": "key", "c": "KeyZ", "d": False})
        await pump(ws, 0.25)
    reader.cancel()
    resyncs = open(log_path).read().count("ack watchdog") - before
    ok("watchdog backs off", 1 <= resyncs <= 2, "%d resyncs in 16 s (without back-off: 4)" % resyncs)
    live.w.close()

    # close: gives up on a peer that never takes the data (the flush never finishes)
    class StuckTransport:
        aborted = closing = False
        def is_closing(self): return self.closing
        def get_write_buffer_size(self): return 1 << 20
        def close(self): self.closing = True       # waits for a flush that never comes
        def abort(self): self.aborted = True

    class StuckWriter:
        def __init__(self, t): self.transport = t
        def writelines(self, parts): pass
        def close(self): self.transport.close()

    sys.path.insert(0, args.root)
    from darpan import web as darpan_web
    stuck = StuckTransport()
    darpan_web.WebSocket(None, StuckWriter(stuck)).close(4003, "disconnected by host")
    await asyncio.sleep(3.3)
    ok("close aborts a stuck peer", stuck.aborted, "after 3 s")

    # changing the password ends existing sessions
    env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(tmp, "config"), XDG_RUNTIME_DIR=os.path.join(tmp, "run"),
               XDG_STATE_HOME=os.path.join(tmp, "state"), XDG_DATA_HOME=os.path.join(tmp, "data"), HOME=tmp,
               PYTHONPATH=args.root)
    subprocess.run([sys.executable, "-m", "darpan", "password", "--generate"], env=env, cwd=args.root,
                   capture_output=True, timeout=20)
    code = None
    end = time.monotonic() + 4
    while time.monotonic() < end and code is None:
        try:
            kind, m = await asyncio.wait_for(ws.recv(), 0.5)
            if kind == "close":
                code = m
        except asyncio.TimeoutError:
            pass
        except (asyncio.IncompleteReadError, ConnectionError):
            break
    ok("password change ends sessions", code == 4003, "close code %s" % code)
    ws.w.close()
    return all(r for _, r in results), results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--display", default=None, help="default: a free display chosen by Xvfb")
    ap.add_argument("--port", type=int, default=47490)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--root", default=ROOT, help="tree to test (e.g. an extracted .deb's opt/darpan)")
    ap.add_argument("--serve", action="store_true", help="set everything up, print JSON, wait (for browser tests)")
    ap.add_argument("--socket-activate", action="store_true", help="hand the host its socket like systemd does")
    args = ap.parse_args()
    args.probe_w, args.probe_h = 1280, 720
    tmp = tempfile.mkdtemp(prefix="darpan-test-")
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(2))   # make sure `finally` cleanup runs
    procs = []
    if not args.display:
        n = next(n for n in range(80, 400) if not os.path.exists("/tmp/.X11-unix/X%d" % n)
                 and not os.path.exists("/tmp/.X%d-lock" % n))
        args.display = ":%d" % n
        procs.append(subprocess.Popen(["Xvfb", args.display, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"],
                                      stderr=subprocess.DEVNULL))
        for _ in range(50):
            if os.path.exists("/tmp/.X11-unix/X%d" % n):
                break
            time.sleep(0.1)
    env = dict(os.environ, DISPLAY=args.display, XDG_CONFIG_HOME=os.path.join(tmp, "config"),
               XDG_STATE_HOME=os.path.join(tmp, "state"), XDG_DATA_HOME=os.path.join(tmp, "data"),
               XDG_RUNTIME_DIR=os.path.join(tmp, "run"), HOME=tmp, PYTHONPATH=args.root)
    os.makedirs(env["XDG_RUNTIME_DIR"], mode=0o700)
    os.makedirs(os.path.join(tmp, "config", "darpan"), mode=0o700)
    with open(os.path.join(tmp, "config", "darpan", "config.json"), "w") as f:
        json.dump({"ping_every": 1, "silent_limit": 6}, f)     # liveness in seconds, not minutes
    try:
        probe_log = os.path.join(tmp, "probe.log")
        probe = subprocess.Popen([sys.executable, "-c", PROBE_APP, str(args.probe_w), str(args.probe_h)], env=env,
                                 stdout=open(probe_log, "w"), stderr=subprocess.STDOUT)
        procs.append(probe)
        host_log = open(os.path.join(tmp, "host.log"), "w")
        cmd = [sys.executable, "-m", "darpan", "serve", "--port", str(args.port), "-v"]
        if args.socket_activate:   # exercise the sd_listen_fds path (darpan.socket in production)
            keep = ["DISPLAY", "HOME", "PATH", "PYTHONPATH", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
                    "XDG_RUNTIME_DIR"]            # it starts children with a clean environment
            cmd = ["systemd-socket-activate", "-l", "127.0.0.1:%d" % args.port] + [a for k in keep for a in ("-E", k)] + cmd
        host = subprocess.Popen(cmd, env=env,
                                stdout=host_log, stderr=subprocess.STDOUT, cwd=args.root)
        procs.append(host)
        if args.socket_activate:   # the socket exists before the host: the first connection starts it
            import socket as _s
            for _ in range(50):
                try:
                    _s.create_connection(("127.0.0.1", args.port), 0.5).close()
                    break
                except OSError:
                    time.sleep(0.1)
        for _ in range(50):
            time.sleep(0.2)
            if os.path.exists(os.path.join(tmp, "config", "darpan", "password.txt")):
                try:
                    import socket
                    socket.create_connection(("127.0.0.1", args.port), 0.2).close()
                    break
                except OSError:
                    pass
        if args.serve:
            pw = open(os.path.join(tmp, "config", "darpan", "password.txt")).read().strip()
            print(json.dumps({"port": args.port, "password": pw, "display": args.display, "probe_log": probe_log,
                              "tmp": tmp, "host_log": os.path.join(tmp, "host.log")}), flush=True)
            signal.signal(signal.SIGINT, lambda *a: sys.exit(0))
            restart = []
            signal.signal(signal.SIGUSR1, lambda *a: restart.append(1))
            while True:
                if restart:                      # browser test: host restart → client must reconnect
                    restart.clear()
                    host.terminate()
                    host.wait(10)
                    host = subprocess.Popen(cmd, env=env, stdout=host_log, stderr=subprocess.STDOUT, cwd=args.root)
                    procs.append(host)
                elif host.poll() is not None:
                    return 1
                time.sleep(0.2)
        print("Darpan host test on %s (tmp %s)" % (args.display, tmp))
        good, _ = asyncio.run(run(args, tmp, probe_log))
        print("\nRESULT:", "ALL PASS" if good else "FAILURES")
        return 0 if good else 1
    finally:
        signal.signal(signal.SIGINT, signal.SIG_IGN)     # a repeated Ctrl-C must not cut cleanup short
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        for p in reversed(procs):
            p.terminate()
            try:
                p.wait(3)
            except subprocess.TimeoutExpired:
                p.kill()
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print("kept", tmp)


if __name__ == "__main__":
    sys.exit(main())
