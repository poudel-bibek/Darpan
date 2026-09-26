"""Video sources. Both expose the same small interface to a session:

    start()  credit(n)  keyframe()  bitrate(kbps)  fps(n)  refresh()  stop()
    callbacks: on_start(w, h, encoder)  on_frame(flags, ts_us, cap_us, enc_us, data)  on_exit(reason)

NvencCapture drives native/darpan-capture (damage-driven XShm -> CUDA -> NVENC, ~0 CPU).
X264Capture is the safety net when NVENC is unavailable (e.g. the NVIDIA driver is being
updated): GStreamer ximagesrc + x264, same flow control, more CPU.
"""
import asyncio
import json
import logging
import os
import struct
import time

from . import config

log = logging.getLogger("darpan.capture")

_REC = struct.Struct("<IIQII")
FLAG_KEY, FLAG_REFRESH, FLAG_INFO = 0x1, 0x2, 0x80000000


async def probe_nvenc(gpu=0):
    if not os.access(config.CAPTURE_BIN, os.X_OK):
        return None
    try:
        proc = await asyncio.create_subprocess_exec(config.CAPTURE_BIN, "--probe", "--gpu", str(gpu),
                                                    stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(), 20)
        info = json.loads(out.decode() or "{}")
        if info.get("nvenc"):
            return info.get("gpu") or "NVIDIA GPU"
        log.info("NVENC unavailable: %s", err.decode(errors="replace").strip())
    except Exception as e:
        log.info("NVENC probe failed: %s", e)
    return None


class _Source:
    def __init__(self, display, fps, kbps, credits, on_start, on_frame, on_exit):
        self.display, self.fps_, self.kbps, self.credits = display, fps, kbps, credits
        self.on_start, self.on_frame, self.on_exit = on_start, on_frame, on_exit
        self.stopped = False


class NvencCapture(_Source):
    encoder = "nvenc"

    def __init__(self, *a, preset=3, gpu=0, **kw):
        super().__init__(*a, **kw)
        self.preset, self.gpu = preset, gpu
        self.proc = None
        self.task = None

    async def start(self):
        args = [config.CAPTURE_BIN, "--fps", str(self.fps_), "--bitrate", str(self.kbps),
                "--credits", str(self.credits), "--preset", str(self.preset), "--gpu", str(self.gpu)]
        if self.display:
            args += ["--display", self.display]
        self.proc = await asyncio.create_subprocess_exec(
            *args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=None,
            limit=1 << 20)
        self.task = asyncio.get_running_loop().create_task(self._read())

    async def _read(self):
        reason = "exit"
        rd = self.proc.stdout
        try:
            while True:
                hdr = await rd.readexactly(_REC.size)
                n, flags, ts, cap_us, enc_us = _REC.unpack(hdr)
                data = await rd.readexactly(n) if n else b""
                if flags & FLAG_INFO:
                    info = json.loads(data)
                    ev = info.get("ev")
                    if ev == "start":
                        self.on_start(info["w"], info["h"], "nvenc")
                    elif ev in ("resize", "error"):
                        reason = ev
                        log.info("capture %s: %s", ev, info)
                    continue
                self.on_frame(flags, ts, cap_us, enc_us, data)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        except Exception:
            log.exception("capture reader failed")
            reason = "error"
        rc = await self.proc.wait()
        if rc == 3:
            reason = "resize"
        elif rc == 4:
            reason = "no-nvenc"
        elif rc not in (0, -15) and reason == "exit":
            reason = "error"
        if not self.stopped:
            self.on_exit(reason)

    def _cmd(self, line):
        p = self.proc
        if p and p.returncode is None and p.stdin and not p.stdin.is_closing():
            try:
                p.stdin.write(line.encode() + b"\n")
            except (BrokenPipeError, ConnectionResetError):
                pass

    def credit(self, n=1):
        self._cmd("c %d" % n)

    def keyframe(self):
        self._cmd("k")

    def bitrate(self, kbps):
        self.kbps = kbps
        self._cmd("b %d" % kbps)

    def fps(self, n):
        self.fps_ = n
        self._cmd("f %d" % n)

    def refresh(self):
        self._cmd("r")

    def pause(self):
        self._cmd("p")

    async def stop(self):
        self.stopped = True
        p = self.proc
        if p and p.returncode is None:
            self._cmd("q")
            try:
                await asyncio.wait_for(p.wait(), 2)
            except asyncio.TimeoutError:
                p.kill()
                await p.wait()
        if self.task:
            self.task.cancel()


class X264Capture(_Source):
    """GStreamer fallback. Frames are dropped *before* the encoder while no credits are
    available, so the encoder never sees gaps it would have to reference across."""
    encoder = "x264"

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.pipe = None
        self.loop = None
        self._t_frame = 0.0

    async def start(self):
        import gi
        gi.require_version("Gst", "1.0")
        from gi.repository import Gst
        Gst.init(None)
        self.Gst = Gst
        self.loop = asyncio.get_running_loop()
        disp = ('display-name="%s" ' % self.display) if self.display else ""
        desc = (
            "ximagesrc %s use-damage=false show-pointer=false ! video/x-raw,framerate=%d/1 "
            "! queue max-size-buffers=1 leaky=downstream ! videoconvert n-threads=4 name=conv "
            "! video/x-raw,format=I420 "
            "! x264enc name=enc tune=zerolatency speed-preset=superfast bitrate=%d vbv-buf-capacity=300 "
            "key-int-max=0 bframes=0 threads=4 "
            "! video/x-h264,stream-format=byte-stream,alignment=au,profile=high "
            "! appsink name=sink emit-signals=true sync=false max-buffers=8 drop=false"
        ) % (disp, self.fps_, self.kbps)
        self.pipe = Gst.parse_launch(desc)
        enc = self.pipe.get_by_name("enc")
        enc.get_static_pad("sink").add_probe(Gst.PadProbeType.BUFFER, self._gate)
        sink = self.pipe.get_by_name("sink")
        sink.connect("new-sample", self._on_sample)
        bus = self.pipe.get_bus()
        self.pipe.set_state(Gst.State.PLAYING)
        self._started = False
        self.loop.create_task(self._watch_bus(bus))

    def _gate(self, pad, info):
        Gst = self.Gst
        now = time.monotonic()
        if self.credits <= 0 or now - self._t_frame < 1.0 / max(1, self.fps_):
            return Gst.PadProbeReturn.DROP
        self._t_frame = now
        self.credits -= 1
        if not self._started:
            self._started = True
            caps = pad.get_current_caps().get_structure(0)
            w, h = caps.get_value("width"), caps.get_value("height")
            self.loop.call_soon_threadsafe(self.on_start, w, h, "x264")
        return Gst.PadProbeReturn.OK

    def _on_sample(self, sink):
        Gst = self.Gst
        sample = sink.emit("pull-sample")
        buf = sample.get_buffer()
        ok, mi = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK
        data = bytes(mi.data)
        buf.unmap(mi)
        key = 0 if buf.has_flags(Gst.BufferFlags.DELTA_UNIT) else FLAG_KEY
        ts = int(time.monotonic() * 1e6)
        self.loop.call_soon_threadsafe(self.on_frame, key, ts, 0, 0, data)
        return Gst.FlowReturn.OK

    async def _watch_bus(self, bus):
        Gst = self.Gst
        while not self.stopped:
            msg = bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if msg:
                if msg.type == Gst.MessageType.ERROR:
                    err, dbg = msg.parse_error()
                    log.warning("x264 pipeline error: %s", err.message)
                if not self.stopped:
                    self.pipe.set_state(Gst.State.NULL)
                    self.on_exit("error")
                return
            await asyncio.sleep(0.25)

    def credit(self, n=1):
        self.credits = min(64, self.credits + n)

    def keyframe(self):
        Gst = self.Gst
        st = Gst.Structure.new_from_string("GstForceKeyUnit, all-headers=(boolean)true")
        self.pipe.get_by_name("sink").send_event(Gst.Event.new_custom(Gst.EventType.CUSTOM_UPSTREAM, st))

    def bitrate(self, kbps):
        self.kbps = kbps
        self.pipe.get_by_name("enc").set_property("bitrate", int(kbps))

    def fps(self, n):
        self.fps_ = n

    def refresh(self):
        pass  # ximagesrc produces frames continuously

    def pause(self):
        self.credits = 0

    async def stop(self):
        self.stopped = True
        if self.pipe:
            self.pipe.set_state(self.Gst.State.NULL)
            self.pipe = None
