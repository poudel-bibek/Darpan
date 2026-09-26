"""The Hub owns everything shared (X11, auth, clipboard, cursor, screen mode); each
WebSocket gets a Session that speaks PROTOCOL.md."""
import asyncio
import base64
import collections
import json
import logging
import math
import os
import re
import secrets
import struct
import time
import zlib

from . import audio
from . import auth, capture, config, files, keymap, tailscale
from .clipboard import Clipboard
from .screen import Screen
from .x11 import BUTTONS, X11, find_display, png_rgba

log = logging.getLogger("darpan.session")

VHDR = struct.Struct(">BBHIQ")
FILE_HDR = struct.Struct(">BI")
UPLOAD_QUEUE_MAX = 2 << 20      # received but not yet written, per upload (clients keep ≤ 512 KiB)
AUTH_TIMEOUT = 10               # s to sign in; clients connect only once they have the password
UNAUTHED_MAX = 32               # connections not yet signed in, in total and per source
UNAUTHED_PER_SOURCE = 4
AUDIO_TOKEN_TTL = 10            # s to open /audio with a token
SHIFT_KC = keymap.x_keycode("ShiftLeft")
# WM_CLASS names of terminal emulators: there ⌘+letter means Ctrl+Shift+letter (copy, paste, tabs)
TERMINALS = {"gnome-terminal-server", "gnome-terminal", "org.gnome.terminal", "org.gnome.ptyxis", "ptyxis", "kgx",
             "org.gnome.console", "kitty", "alacritty", "org.wezfurlong.wezterm", "xterm", "uxterm", "konsole",
             "tilix", "com.gexperts.tilix", "terminator", "xfce4-terminal", "foot", "st-256color", "urxvt",
             "terminology", "guake", "com.mitchellh.ghostty"}


def _b64(b):
    return base64.b64encode(b).decode()


def _desktop_dir():
    """Where dropped files land: on the desktop itself (XDG_DESKTOP_DIR, normally ~/Desktop)."""
    d = None
    try:
        with open(os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "user-dirs.dirs")) as f:
            for line in f:
                if line.startswith("XDG_DESKTOP_DIR="):
                    d = os.path.expandvars(line.split("=", 1)[1].strip().strip('"'))
    except OSError:
        pass
    return d or os.path.expanduser("~/Desktop")


class RateControl:
    """Delay-based AIMD. The moment frames start queueing somewhere on the path (ack RTT
    rises above the recent minimum by more than the frame's own serialisation time) the
    bitrate drops; it only probes upward while the content actually uses the bits."""

    def __init__(self, start, cap, fps):
        self.cap = max(500, cap)
        self.kbps = min(start, self.cap)
        self.floor = min(1500, self.cap)
        self.fps = fps
        self.win = collections.deque()      # monotonic deque of (t, rtt) for a 10 s min
        self.min_rtt = None
        self.q = 0.0
        self.sent = 0
        self.last = time.monotonic()

    def on_ack(self, now, rtt, size):
        w = self.win
        while w and w[-1][1] >= rtt:
            w.pop()
        w.append((now, rtt))
        while now - w[0][0] > 10:
            w.popleft()
        self.min_rtt = w[0][1]
        q = rtt - self.min_rtt - size * 8.0 / (self.kbps * 1000.0)
        self.q += 0.25 * ((q if q > 0 else 0.0) - self.q)

    def tick(self, now):
        dt = now - self.last
        if dt < 0.5:
            return None
        used = self.sent * 8 / dt / 1000.0
        self.sent = 0
        self.last = now
        old = self.kbps
        if self.q > 0.045:
            self.kbps = max(self.floor, int(self.kbps * 0.7))
        elif self.q < 0.010 and used > 0.6 * self.kbps:
            self.kbps = min(self.cap, int(self.kbps * 1.15) + 250)
        return self.kbps if self.kbps != old else None

    def window(self):
        if self.min_rtt is None:
            return 4
        return max(3, min(12, math.ceil(self.min_rtt * self.fps) + 2))


class Upload:
    def __init__(self, fid, name, size):
        self.fid, self.size, self.n = fid, size, 0
        name = os.path.basename(str(name).replace("\\", "/"))
        name = re.sub(r"[\x00-\x1f\x7f]", "", name).strip()
        name = name.encode()[:200].decode("utf-8", "ignore").strip()   # ≤ 200 bytes (NAME_MAX is 255)
        if name in ("", ".", ".."):
            name = "file"
        self.name = name
        self.dir = _desktop_dir()
        os.makedirs(self.dir, exist_ok=True)
        self.tmp = os.path.join(self.dir, ".darpan-upload-%s.part" % secrets.token_hex(6))
        self.f = open(self.tmp, "xb")
        self.received = 0                  # bytes accepted from the socket (≥ n, the bytes on disk)
        self.q = asyncio.Queue()           # chunks waiting for the writer (received - n bytes)
        self.task = None

    def write(self, data):
        self.f.write(data)
        self.n += len(data)

    def finish(self):
        self.f.close()
        base, ext = os.path.splitext(self.name)
        path, i = os.path.join(self.dir, self.name), 1
        while os.path.exists(path):
            path = os.path.join(self.dir, "%s (%d)%s" % (base, i, ext))
            i += 1
        os.rename(self.tmp, path)
        return path

    def abort(self):
        try:
            self.f.close()
            os.unlink(self.tmp)
        except OSError:
            pass


class Session:
    def __init__(self, hub, ws, source, headers):
        self.hub, self.ws, self.source = hub, ws, source
        self.sid = secrets.token_hex(6)
        self.ua = headers.get("user-agent", "")[:160]
        self.ts_user = headers.get("tailscale-user-login")
        self.client = self.ua
        self.since = time.time()
        self.authed = False
        # video
        self.cap = None
        self.stream_id = 0
        self.seq = 0
        self.w = self.h = 0
        self.params = None
        self.paused_at = None
        self.inflight = {}
        self.window = 4
        self.withhold = 0
        self.rc = None
        self.errors = collections.deque()
        self.x264_until = 0.0            # NVENC failed (e.g. VRAM full): software until then, then retry
        self.x264_backoff = 60.0
        self.last_kf = 0.0
        self.wd_after = 3.0              # ack watchdog: 3 s, doubling while acks stay away
        self.last_ping = 0.0
        self.busy = False                # awaiting a slow handler (typing a long text)
        self._kf_pending = False
        self._cap_lock = asyncio.Lock()  # start/stop/restart never overlap (no orphaned encoders)
        self.stats = [0, 0, 0, 0]   # frames, bytes, cap_us, enc_us  (this second)
        self.last_stats = time.monotonic()
        # input
        self.keys = set()
        self.cmd_shift = set()           # keys pressed with a Shift we added (⌘ in a terminal)
        self.buttons = set()
        self.wacc = [0, 0]
        self.cursors_sent = set()
        self.uploads = {}
        self.tasks = set()
        self.sound = set()               # this viewer's /audio sockets

    # ------------------------------------------------------------------ lifecycle
    async def run(self):
        hub, ws = self.hub, self.ws
        nonce = os.urandom(32)
        salt = hub.auth.salt or os.urandom(16)
        ws.send_json({"t": "hello", "proto": config.PROTO, "app": config.APP, "ver": config.VERSION,
                      "host": config.hostname(), "nonce": _b64(nonce),
                      "kdf": {"alg": "pbkdf2-sha256", "salt": _b64(salt), "iter": hub.auth.iterations}})
        deadline = time.monotonic() + AUTH_TIMEOUT
        try:
            while True:
                msg = await asyncio.wait_for(ws.recv(), max(0.1, deadline - time.monotonic()))
                if msg is None:
                    return
                if not msg[0]:
                    continue
                m = json.loads(msg[1])
                if not isinstance(m, dict) or m.get("t") != "auth":
                    continue
                if not self._authenticate(m, nonce):
                    return
                break
        except asyncio.TimeoutError:
            hub.limiter.failure(self.source)   # holding a connection without signing in counts too
            ws.close(4002, "auth timeout")
            return
        except ValueError:
            ws.close(4000, "bad message")
            return

        if not await hub.attach():
            ws.close(4004, "no screen yet")
            return
        hub.sessions.add(self)
        hub._active.set()
        if len(hub.sessions) == 1:
            self._task(hub.restore_resolution(self))
        try:
            self._welcome()
            while True:
                msg = await ws.recv()
                if msg is None:
                    break
                if msg[0]:
                    try:
                        m = json.loads(msg[1])
                        h = self.HANDLERS.get(m.get("t")) if isinstance(m, dict) else None
                        if h:
                            r = h(self, m)
                            if r is not None:   # ordering matters (e.g. clip before the paste key)
                                self.busy = True    # frames from the peer wait unread meanwhile
                                try:
                                    await r
                                finally:
                                    self.busy = False
                                    ws.last_rx = time.monotonic()
                    except (ValueError, TypeError, KeyError) as e:
                        log.debug("bad message from %s: %s", self.sid, e)
                    except Exception:
                        log.exception("handler failed for %r", msg[1][:80])
                else:
                    try:
                        self._on_binary(msg[1])
                    except Exception:
                        log.exception("binary handler failed")
        finally:
            await self._close()

    def _authenticate(self, m, nonce):
        hub, ws = self.hub, self.ws
        wait = hub.limiter.retry_after(self.source)
        if wait:
            ws.send_json({"t": "denied", "reason": "locked", "retry": wait})
            ws.close(4001, "locked")
            return False
        if not hub.auth.configured:
            ws.send_json({"t": "denied", "reason": "no_password", "retry": 0})
            ws.close(4001, "no password set")
            return False
        if not hub.auth.verify(nonce, m.get("proof", "")):
            hub.limiter.failure(self.source)
            log.warning("bad password from %s (%s)", self.source, self.ua[:60])
            ws.send_json({"t": "denied", "reason": "password", "retry": hub.limiter.retry_after(self.source)})
            ws.close(4001, "bad password")
            return False
        if len(hub.sessions) >= hub.cfg["max_sessions"]:
            ws.send_json({"t": "denied", "reason": "busy", "retry": 5})
            ws.close(4005, "too many sessions")
            return False
        hub.limiter.success(self.source)
        self.authed = True
        hub.unauthed -= 1
        hub._unauthed_done(self.source)
        self.client = str(m.get("client") or self.ua)[:120]
        log.info("session %s: %s from %s%s", self.sid, self.client, self.source,
                 " (%s)" % self.ts_user if self.ts_user else "")
        return True

    def _welcome(self):
        hub = self.hub
        hub._refresh_url()
        w, h = hub.x.size
        self.ws.send_json({"t": "ok", "sid": self.sid, "screen": {"w": w, "h": h}, "codecs": ["h264"],
                           "caps": ["clip", "files", "text", "cursor", "res", "fs"] + (["audio"] if hub.audio_ok else []),
                           "url": hub.url,
                           "enc": "nvenc" if hub.encoder else "x264", "gpu": hub.encoder})
        if hub.modes:
            self.ws.send_json(dict(hub.modes, t="modes"))
        if hub.cursor_dirty:
            hub._update_cursor()
        self.send_cursor(hub.cursor_id)
        self._task(hub.send_clipboard(self))

    async def _close(self):
        hub = self.hub
        hub.sessions.discard(self)
        for t in [t for t, (s, _) in hub.audio_tokens.items() if s is self]:
            del hub.audio_tokens[t]
        hub.files.forget(self)             # its file token dies and its transfers stop
        for ws in list(self.sound):
            ws.close(4003, "session ended")
        writers = [u.task for u in self.uploads.values() if u.task]
        for t in list(self.tasks):
            t.cancel()
        await asyncio.gather(*writers, return_exceptions=True)   # they delete their partial files
        self.uploads.clear()
        await self._stop_capture()
        self._release_all()
        if self.authed:
            log.info("session %s closed", self.sid)
        await hub.session_ended()

    def _task(self, coro):
        t = asyncio.get_running_loop().create_task(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)
        return t

    def kick(self, code=4003, reason="disconnected by host"):
        self.ws.send_json({"t": "bye", "reason": reason})
        self.ws.close(code, reason)

    # ------------------------------------------------------------------ video
    def on_start(self, m):
        if m.get("codec", "h264") != "h264":
            self.ws.send_json({"t": "notice", "level": "error", "text": "unsupported codec"})
            return
        fps = int(m.get("fps") or self.hub.cfg["fps"])
        self.params = {"fps": max(1, min(120, fps)), "bitrate": max(0, int(m.get("bitrate") or 0))}
        if self.cap and self.paused_at is not None and self.cap.fps_ == self.params["fps"]:
            self._resume()
        else:
            self._task(self._start_capture())

    def on_stop(self, m):
        if self.cap and self.paused_at is None:
            self.paused_at = time.monotonic()   # keep the encoder warm for a quick resume
            self.cap.pause()

    def on_cfg(self, m):
        if not self.params:
            return
        if "fps" in m:
            self.params["fps"] = max(1, min(120, int(m["fps"])))
            if self.cap:
                self.cap.fps(self.params["fps"])
            if self.rc:
                self.rc.fps = self.params["fps"]
        if "bitrate" in m:
            b = max(0, int(m["bitrate"]))
            self.params["bitrate"] = b
            if self.rc:
                self.rc.cap = b or self.hub.cfg["max_kbps"]
                target = min(self.rc.kbps if not b else b, self.rc.cap)
                self.rc.kbps = target
                if self.cap:
                    self.cap.bitrate(target)

    def on_kf(self, m):
        # At most one forced key frame per second, but never drop a request: with an infinite
        # GOP a dropped one would leave the client waiting for a key frame forever.
        if not self.cap:
            return
        wait = self.last_kf + 1.0 - time.monotonic()
        if wait <= 0:
            self.last_kf = time.monotonic()
            self.cap.keyframe()
        elif not self._kf_pending:
            self._kf_pending = True

            def later():
                self._kf_pending = False
                if self.cap:
                    self.last_kf = time.monotonic()
                    self.cap.keyframe()
            asyncio.get_running_loop().call_later(wait, later)

    def on_ack(self, m):
        if m.get("id") != self.stream_id:
            return
        n = m.get("n")
        ent = self.inflight.pop(n, None)
        if ent is None:
            return
        now = time.monotonic()
        give = 1
        for s in [s for s in self.inflight if s < n]:   # frames the client skipped
            del self.inflight[s]
            give += 1
        self.wd_after = 3.0
        self.rc.on_ack(now, now - ent[0], ent[1])
        self._credit(give)

    def _credit(self, n):
        if self.withhold:
            k = min(self.withhold, n)
            self.withhold -= k
            n -= k
        if n and self.cap and self.paused_at is None:
            self.cap.credit(n)

    async def _start_capture(self, restart=False):
        async with self._cap_lock:
            await self._stop_capture_locked()
            await self._start_capture_locked(restart)

    async def _start_capture_locked(self, restart):
        hub, p = self.hub, self.params
        cfg = hub.cfg
        cap_kbps = p["bitrate"] or cfg["max_kbps"]
        if not self.rc or not restart:
            self.rc = RateControl(cfg["start_kbps"] if not p["bitrate"] else p["bitrate"], cap_kbps, p["fps"])
        self.window = self.rc.window()
        self.withhold = 0
        use_nvenc = hub.encoder and time.monotonic() >= self.x264_until and cfg["encoder"] != "x264"
        cls = capture.NvencCapture if use_nvenc else capture.X264Capture
        kw = {"preset": cfg["preset"], "gpu": cfg["gpu"], "cuda": hub.no_vulkan} if use_nvenc else {}
        fps = p["fps"] if use_nvenc else min(p["fps"], 30)   # software encoding: spare the CPU
        self.stream_id = (self.stream_id % 0xFFFF) + 1
        self.seq = 0
        self.inflight.clear()
        self.wd_after = 3.0
        self.paused_at = None
        mine = []

        def current(fn):            # a replaced capture's queued frames and events are stale
            return lambda *a: fn(*a) if mine and mine[0] is self.cap else None

        self.cap = cls(hub.display, fps, self.rc.kbps, self.window, on_start=current(self._cap_started),
                       on_frame=current(self._cap_frame), on_exit=current(self._cap_exit), **kw)
        mine.append(self.cap)
        try:
            await self.cap.start()
        except Exception as e:
            log.exception("capture start failed")
            self.ws.send_json({"t": "notice", "level": "error", "text": "screen capture failed: %s" % e})
            self.cap = None

    async def _stop_capture(self):
        async with self._cap_lock:
            await self._stop_capture_locked()

    async def _stop_capture_locked(self):
        cap, self.cap = self.cap, None
        if cap:
            await cap.stop()

    def _resume(self):
        self.paused_at = None
        self.withhold = 0                 # fresh window: a shrink pending from before the pause is moot
        self.stream_id = (self.stream_id % 0xFFFF) + 1
        self.seq = 0
        self.inflight.clear()
        self.wd_after = 3.0
        self.ws.send_json({"t": "stream", "id": self.stream_id, "codec": "h264", "w": self.w, "h": self.h,
                           "fps": self.params["fps"], "enc": self.cap.encoder})
        self.cap.keyframe()
        self.cap.refresh()
        self.cap.credit(self.window)

    def _cap_started(self, w, h, enc):
        self.w, self.h = w, h
        self.ws.send_json({"t": "stream", "id": self.stream_id, "codec": "h264", "w": w, "h": h,
                           "fps": self.params["fps"], "enc": enc})

    def _cap_frame(self, flags, ts, cap_us, enc_us, data):
        if self.paused_at is not None or self.ws.closed:
            return
        seq = self.seq
        self.seq = (seq + 1) & 0xFFFFFFFF
        n = len(data)
        self.inflight[seq] = (time.monotonic(), n)
        self.ws.send_binary(VHDR.pack(1, flags & 3, self.stream_id, seq, ts), data)
        self.rc.sent += n
        st = self.stats
        st[0] += 1
        st[1] += n
        st[2] += cap_us
        st[3] += enc_us

    def _cap_exit(self, reason):
        if self.ws.closed or not self.params:
            return
        now = time.monotonic()
        if reason == "resize":
            delay = 0.3
        elif reason == "no-nvenc":
            self._fall_back_to_x264("NVENC unavailable (GPU memory full?)")
            delay = 0
        elif reason == "vulkan":                   # the same NVENC through CUDA, for as long as we run
            log.warning("session %s: Vulkan Video failed — NVENC through CUDA from now on", self.sid)
            self.hub.no_vulkan = True
            delay = 0
        else:
            self.errors.append(now)
            while self.errors and now - self.errors[0] > 60:
                self.errors.popleft()
            if len(self.errors) >= 3 and time.monotonic() >= self.x264_until:
                self._fall_back_to_x264("NVENC keeps failing")
            delay = min(5, len(self.errors))
        if self.paused_at is not None:
            # The viewer is hidden: leave the encoder down until it sends `start` again.
            self.cap = None
            return

        async def later():
            await asyncio.sleep(delay)
            if not self.ws.closed:
                await self._start_capture(restart=True)
        self._task(later())

    def _fall_back_to_x264(self, why):
        log.warning("session %s: %s — software encoding for %d s, then NVENC again", self.sid, why,
                    self.x264_backoff)
        self.x264_until = time.monotonic() + self.x264_backoff
        self.x264_backoff = min(900.0, self.x264_backoff * 2)

    def tick(self, now):
        """Once a second: liveness, stats, congestion control, watchdog, idle encoder teardown."""
        cfg = self.hub.cfg
        if not self.busy and now - self.ws.last_rx > cfg["silent_limit"]:
            # Every WebSocket client answers pings, so silence this long means the peer is gone
            # (e.g. a killed process whose connection never closed). Free its encoder now.
            log.info("session %s: no reply for %d s, closing", self.sid, cfg["silent_limit"])
            self.ws.abort()
            return
        if now - self.last_ping >= cfg["ping_every"]:
            self.last_ping = now
            self.ws.ping()
        if not self.cap:
            return
        if (self.cap.encoder == "x264" and self.hub.encoder and self.x264_until and now >= self.x264_until
                and self.paused_at is None and not self._cap_lock.locked()):
            self.x264_until = 0.0                      # retry NVENC (training may have freed VRAM)
            self._task(self._start_capture(restart=True))
            return
        if self.paused_at is not None:
            if now - self.paused_at > 15:
                self._task(self._stop_capture())
            return
        new = self.rc.tick(now)
        if new is not None:
            self.cap.bitrate(new)
        win = self.rc.window()
        if win > self.window:
            self._credit(win - self.window)
        elif win < self.window:
            self.withhold += self.window - win
        self.window = win
        if self.inflight:
            oldest = min(t for t, _ in self.inflight.values())
            # Acks stopped: resync from a key frame so we never deadlock — unless the socket itself
            # is backed up (link stalled): queueing more frames would only add latency.
            if now - oldest > self.wd_after and self.ws.buffered < 256 * 1024:
                log.info("session %s: ack watchdog, resyncing (next after %d s)", self.sid, min(30, self.wd_after * 2))
                k = len(self.inflight)
                self.inflight.clear()
                self._credit(k)
                self.cap.keyframe()
                self.wd_after = min(30.0, self.wd_after * 2)   # a peer that never acks gets fewer key frames
        f, b, c, e = self.stats
        dt = now - self.last_stats
        self.last_stats = now
        if f:
            self.ws.send_json({"t": "stats", "fps": round(f / dt, 1), "kbps": int(b * 8 / dt / 1000),
                               "cap_ms": round(c / f / 1000, 2), "enc_ms": round(e / f / 1000, 2),
                               "br": self.rc.kbps, "win": self.window,
                               "rtt": round((self.rc.min_rtt or 0) * 1000, 1), "q": round(self.rc.q * 1000, 1)})
        self.stats = [0, 0, 0, 0]

    # ------------------------------------------------------------------ input
    def _xy(self, m):
        sw, sh = self.hub.x.size
        x, y = int(m["x"]), int(m["y"])
        if self.w and (self.w, self.h) != (sw, sh):
            x, y = x * sw // self.w, y * sh // self.h
        return max(0, min(sw - 1, x)), max(0, min(sh - 1, y))

    def on_mm(self, m):
        self.hub.x.motion(*self._xy(m))

    def on_mb(self, m):
        b = BUTTONS.get(m.get("b"))
        if not b:
            return
        down = bool(m.get("d"))
        if "x" in m:
            self.hub.x.motion(*self._xy(m))
        (self.buttons.add if down else self.buttons.discard)(b)
        self.hub.x.button(b, down)

    def on_wh(self, m):
        for i, (neg, pos) in enumerate(((4, 5), (6, 7))):
            v = int(m.get("dy" if i == 0 else "dx", 0))
            if not v:
                continue
            self.wacc[i] += max(-120 * 50, min(120 * 50, v))
            clicks = int(self.wacc[i] / 120)
            if clicks:
                self.wacc[i] -= clicks * 120
                self.hub.x.wheel(pos if clicks > 0 else neg, abs(clicks))

    def on_key(self, m):
        kc = keymap.x_keycode(m.get("c"))
        if kc is None:
            return
        down = bool(m.get("d"))
        self.hub.begin_control()
        x = self.hub.x
        if down and kc in self.keys:
            # Client-driven auto-repeat. With host auto-repeat off the X server ignores a
            # press of a key that is already down, so each repeat is sent as up+down.
            x.key(kc, False)
        elif (down and m.get("cmd") and str(m.get("c")).startswith("Key") and SHIFT_KC not in self.keys
              and any(n in TERMINALS for n in x.focused_class())):
            # ⌘+letter (sent as Ctrl) in a terminal is the terminal's shortcut, Ctrl+Shift+letter;
            # ⌃ stays the shell's Ctrl. The Shift lasts until this key goes up.
            x.key(SHIFT_KC, True)
            self.cmd_shift.add(kc)
        (self.keys.add if down else self.keys.discard)(kc)
        x.key(kc, down)
        if not down and kc in self.cmd_shift:
            self.cmd_shift.discard(kc)
            # the last ⌘ letter lets go of our Shift; never one the user is holding
            if not self.cmd_shift and SHIFT_KC not in self.keys:
                x.key(SHIFT_KC, False)

    def on_rel(self, m):
        self._release_all()

    def _release_all(self):
        x = self.hub.x
        for kc in self.keys:
            x.key(kc, False)
        if self.cmd_shift:
            x.key(SHIFT_KC, False)
            self.cmd_shift.clear()
        for b in self.buttons:
            x.button(b, False)
        self.keys.clear()
        self.buttons.clear()

    def on_txt(self, m):
        s = str(m.get("s", ""))[:4096]
        if s:
            return self.hub.type_text(s)   # awaited: later keys can't overtake the text

    def on_clip(self, m):
        # Awaited by the receive loop: the host clipboard holds the new text before the next
        # message (typically the paste shortcut) is injected.
        text = m.get("text")
        if isinstance(text, str) and len(text) <= 1 << 20:
            return self.hub.set_clipboard(text, self)

    def on_ping(self, m):
        self.ws.send_json({"t": "pong", "c": m.get("c"), "s": int(time.monotonic() * 1e6)})

    def send_cursor(self, cid):
        if cid is None:
            return
        full = self.hub.cursor_cache.get(cid)
        if cid and full and cid not in self.cursors_sent:
            self.cursors_sent.add(cid)
            self.ws.send_json(full)
        else:
            self.ws.send_json({"t": "cur", "id": cid})

    # ------------------------------------------------------------------ resolution
    def on_res(self, m):
        self._task(self.hub.change_resolution(self, m))

    def on_modes(self, m):
        self._task(self.hub.refresh_modes(send_to=self))

    # ------------------------------------------------------------------ sound
    def on_audio(self, m):
        hub = self.hub
        if not m.get("on"):
            for ws in list(self.sound):
                ws.close(1000)
            return
        try:
            if not hub.audio_ok:
                raise OSError("no PipeWire or libopus")
            if time.monotonic() < hub.audio_retry_at:
                raise OSError("capture kept failing; trying again later")
            if hub.audio_pre_skip is None:
                hub.audio_pre_skip = audio.lookahead()
        except OSError as e:
            log.info("sound unavailable: %s", e)
            self.ws.send_json({"t": "audio", "error": "unavailable"})
            return
        self.ws.send_json({"t": "audio", "token": _b64(hub.audio_token(self)), "codec": "opus", "rate": audio.RATE,
                           "channels": audio.CHANNELS, "frame_ms": 10, "pre_skip": hub.audio_pre_skip})

    # ------------------------------------------------------------------ uploads
    def on_fs(self, m):
        self.ws.send_json(self.hub.files.hello(self, _desktop_dir()))

    def on_fput(self, m):
        fid, size = int(m.get("id", 0)) & 0xFFFFFFFF, int(m.get("size", -1))
        if fid in self.uploads or not 0 <= size <= 64 << 30 or len(self.uploads) >= 8:
            self.ws.send_json({"t": "ferr", "id": fid, "e": "rejected"})
            return
        try:
            up = Upload(fid, m.get("name", "file"), size)
        except OSError as e:
            self.ws.send_json({"t": "ferr", "id": fid, "e": str(e)})
            return
        self.uploads[fid] = up
        up.task = self._task(self._upload_writer(up))
        self.ws.send_json({"t": "fok", "id": fid})

    def on_fabort(self, m):
        up = self.uploads.pop(int(m.get("id", 0)), None)
        if up:
            self._cancel_upload(up)

    def _cancel_upload(self, up):
        # A task cancelled before it ever ran skips its own cleanup, so remove the partial file once
        # the task is done either way; by then any in-flight write has finished (abort is idempotent).
        up.task.add_done_callback(lambda _t: up.abort())
        up.task.cancel()

    async def _upload_writer(self, up):
        """Disk writes happen on a worker thread, so a slow disk (checkpointing, writeback) never
        stalls video or input; each fack is sent once its bytes are actually written."""
        loop = asyncio.get_running_loop()
        try:
            while up.n < up.size:
                chunk = await up.q.get()
                fut = loop.run_in_executor(None, up.write, chunk)
                try:
                    await asyncio.shield(fut)
                except asyncio.CancelledError:
                    try:
                        await fut                  # let the in-flight write finish before cleanup
                    except Exception:
                        pass
                    raise
                self.ws.send_json({"t": "fack", "id": up.fid, "n": up.n})
            self._finish_upload(up)
        except OSError as e:
            self.uploads.pop(up.fid, None)
            up.abort()
            self.ws.send_json({"t": "ferr", "id": up.fid, "e": str(e)})
        except asyncio.CancelledError:
            up.abort()
            raise

    def _on_binary(self, data):
        if len(data) < FILE_HDR.size or data[0] != 2:
            return
        _, fid = FILE_HDR.unpack_from(data)
        up = self.uploads.get(fid)
        if not up:
            return
        chunk = data[FILE_HDR.size:]
        if up.received + len(chunk) > up.size:
            self.uploads.pop(fid)
            self._cancel_upload(up)
            self.ws.send_json({"t": "ferr", "id": fid, "e": "too much data"})
            return
        if up.received + len(chunk) - up.n > UPLOAD_QUEUE_MAX:
            # PROTOCOL.md §7 allows 1 MiB un-acked: a client far past it would fill our memory
            self.uploads.pop(fid)
            self._cancel_upload(up)
            self.ws.send_json({"t": "ferr", "id": fid, "e": "flow control: too much un-acked data"})
            return
        up.received += len(chunk)
        up.q.put_nowait(chunk)

    def _finish_upload(self, up):
        self.uploads.pop(up.fid, None)
        try:
            path = up.finish()
        except OSError as e:
            up.abort()                    # never leave a hidden full-size .part behind
            self.ws.send_json({"t": "ferr", "id": up.fid, "e": str(e)})
            return
        log.info("session %s uploaded %s (%d bytes)", self.sid, path, up.size)
        self.ws.send_json({"t": "fdone", "id": up.fid, "path": path})

    HANDLERS = {
        "start": on_start, "stop": on_stop, "cfg": on_cfg, "kf": on_kf, "ack": on_ack,
        "mm": on_mm, "mb": on_mb, "wh": on_wh, "key": on_key, "rel": on_rel, "txt": on_txt,
        "clip": on_clip, "ping": on_ping, "res": on_res, "modes": on_modes,
        "fput": on_fput, "fabort": on_fabort, "audio": on_audio, "fs": on_fs,
    }


def _kind(session):
    """The kind of client, e.g. "Darpan for Mac on macOS" or "Chrome on Windows": its name without
    version numbers. Remembered choices are keyed by it, so no address is stored."""
    return re.sub(r"\s*\d+(?:\.\d+)+", "", session.client).strip()


class Hub:
    def __init__(self, cfg):
        self.cfg = cfg
        self.auth = auth.AuthStore()
        self.limiter = auth.RateLimiter()
        self.sessions = set()
        self.unauthed = 0
        self.display = None
        self.login_screen = False        # nobody is logged in: we show the login screen
        self.x = None
        self.encoder = None
        self.no_vulkan = False           # Vulkan Video broke once: encode through CUDA
        self.url = None
        self.modes = None
        self.clip = None
        self.clip_text = None
        self.cursor_id = None
        self.cursor_cache = collections.OrderedDict()
        self.screen = None
        self.repeat_marker = os.path.join(config.state_dir(), "autorepeat-off")
        self.res_file = os.path.join(config.state_dir(), "resolutions.json")   # each device's last choice
        self._repeat_off = False
        self._cursor_pending = False
        self.cursor_dirty = True       # shapes/clipboard are only read while someone is connected
        self.clip_dirty = True
        self._clip_task = None
        self._active = asyncio.Event()
        self._url_at = -1e9
        self._restore_keymap = None
        self._typing = asyncio.Lock()
        self._screen = asyncio.Lock()     # set_mode / restore never interleave
        self.unauthed_by = collections.Counter()
        self.audio_ok = audio.available()
        self.audio_pre_skip = None
        self.audio_tokens = {}           # token -> (session, expiry): single use, 10 s
        self.listeners = {}              # /audio socket -> [session, dropped since last packet]
        self.sound = None                # audio.Capture while anyone listens
        self.audio_fails = 0
        self.audio_retry_at = 0.0
        self.files = files.Files(self)    # /fs/ requests (PROTOCOL.md §7.1)
        self.loop = None

    async def start(self):
        self.loop = asyncio.get_running_loop()
        await self.attach()
        if self.cfg["encoder"] in ("auto", "nvenc"):
            self.encoder = await capture.probe_nvenc(self.cfg["gpu"])
        log.info("encoder: %s", ("NVENC on " + self.encoder) if self.encoder else "x264 (software)")
        self.loop.create_task(self._housekeeping())
        self._refresh_url()

    async def attach(self):
        """Take the screen: the desktop, or before anyone logs in, the login screen. False while
        there is none yet (the computer is starting up); every sign-in looks again. When the X
        server goes away (log in, log out), so do we, and systemd starts us afresh."""
        if self.x:
            return True
        found = find_display()
        if not found:
            return False
        self.display, self.login_screen = found
        self.clip, self.screen = Clipboard(self.display), Screen(self.display)
        self.x = X11(self.display)
        self.x.on_cursor = self._on_cursor
        self.x.on_clipboard = self._on_clipboard
        self.x.on_resize = self._on_resize
        self.x.watch(self.loop)
        if os.path.exists(self.repeat_marker):     # we crashed while a session had control
            self.x.set_autorepeat(True)
            os.unlink(self.repeat_marker)
        log.info("screen: %s%s", self.display, " (login screen)" if self.login_screen else "")
        if not self.login_screen:                  # the login screen keeps its own resolution
            await self.screen.restore()
            self.loop.create_task(self.refresh_modes())
        return True

    def info(self):
        self._refresh_url()
        return {"app": config.APP, "ver": config.VERSION, "proto": config.PROTO,
                "host": config.hostname(), "url": self.url}

    def _refresh_url(self):
        """Lazily (at most once a minute, off the event loop) learn our https://…ts.net address."""
        now = time.monotonic()
        if now - self._url_at < (60 if self.url else 5):   # retry fast until Tailscale is up
            return
        self._url_at = now

        def fetch():
            st = tailscale.summary()
            return st.get("url") if st.get("state") == "Running" else None

        fut = self.loop.run_in_executor(None, fetch)
        fut.add_done_callback(lambda f: setattr(self, "url", f.result()) if not f.exception() else None)

    # ---------------------------------------------------------------- sound
    def audio_token(self, session):
        now = time.monotonic()
        for t in [t for t, (_, exp) in self.audio_tokens.items() if exp < now]:
            del self.audio_tokens[t]
        for t in [t for t, (s, _) in self.audio_tokens.items() if s is session][:-1]:
            del self.audio_tokens[t]                        # at most 2 live tokens per session
        token = secrets.token_bytes(32)
        self.audio_tokens[token] = (session, now + AUDIO_TOKEN_TTL)
        return token

    async def handle_audio(self, ws, source):
        """A viewer's sound socket: its first message is {"t":"auth","token":…}, then packets flow."""
        if self.unauthed >= UNAUTHED_MAX or self.unauthed_by[source] >= UNAUTHED_PER_SOURCE:
            ws.close(4005, "busy")
            return
        self.unauthed += 1
        self.unauthed_by[source] += 1
        session = None
        try:
            msg = await asyncio.wait_for(ws.recv(), 5)
            m = json.loads(msg[1]) if msg and msg[0] else {}
            token = base64.b64decode(m.get("token", ""), validate=True) if isinstance(m, dict) else b""
            ent = self.audio_tokens.pop(token, None)         # single use
            if ent and ent[1] >= time.monotonic() and ent[0] in self.sessions:
                session = ent[0]
        except (asyncio.TimeoutError, ValueError, TypeError):
            pass
        finally:
            self.unauthed -= 1
            self._unauthed_done(source)
        if not session:                   # a 256-bit token can't be guessed: no lockout for this
            ws.close(4001, "denied")
            return
        ws.send_json({"t": "ok"})
        self.listeners[ws] = [session, True]          # its first packet carries FIRST
        session.sound.add(ws)
        try:
            if self.sound is None:
                try:
                    self._audio_start()
                except OSError as e:                         # e.g. pw-record gone since startup
                    log.warning("sound: %s", e)
                    self._audio_exited(0)                    # the same back-off as a capture that died
            while await ws.recv() is not None:               # nothing to read; wait for the close
                pass
        finally:
            self.listeners.pop(ws, None)
            session.sound.discard(ws)
            if not self.listeners and self.sound:
                self.sound.stop()
                self.sound = None
            if not ws.closed:
                ws.close(1000)

    def _audio_start(self):
        self.sound = audio.Capture(self.loop, self._audio_packet, self._audio_exited)
        try:
            self.sound.start()
        except OSError:
            self.sound = None
            raise

    def _audio_exited(self, ran):
        # PipeWire restarted, say: start again for the listeners, but give up after 3 quick failures
        self.sound = None
        self.audio_fails = 0 if ran > 5 else self.audio_fails + 1
        if self.listeners and self.audio_fails < 3:
            self.loop.call_later(2, self._audio_retry)
        else:
            self.audio_retry_at = time.monotonic() + 60     # no restart loop while PipeWire is broken
            self.audio_fails = 0
            for ws in list(self.listeners):
                ws.close(1011, "sound unavailable")

    def _audio_retry(self):
        if self.sound is None and self.listeners:
            try:
                self._audio_start()
            except OSError as e:
                log.warning("sound: %s", e)
                self._audio_exited(0)

    def _audio_packet(self, pkt):
        for ws, ent in self.listeners.items():
            if ws.buffered > 32 * 1024:          # a slow link: drop sound rather than delay it
                ent[1] = True
                continue
            out = pkt
            if ent[1]:                           # packets were dropped: the client restarts its buffer
                out = pkt[:1] + bytes((pkt[1] | audio.FIRST,)) + pkt[2:]
                ent[1] = False
            ws.send_binary(out)

    def _unauthed_done(self, source):
        self.unauthed_by[source] -= 1
        if self.unauthed_by[source] <= 0:
            del self.unauthed_by[source]

    async def handle(self, ws, source, headers):
        if self.unauthed >= UNAUTHED_MAX or self.unauthed_by[source] >= UNAUTHED_PER_SOURCE:
            ws.send_json({"t": "denied", "reason": "busy", "retry": 5})
            ws.close(4005, "busy")
            return
        s = Session(self, ws, source, headers)
        self.unauthed += 1          # Session decrements both the moment it authenticates
        self.unauthed_by[source] += 1
        try:
            await s.run()
        except Exception:
            log.exception("session crashed")
        finally:
            if not s.authed:
                self.unauthed -= 1
                self._unauthed_done(source)
            if not ws.closed:
                ws.close(1000)

    async def _housekeeping(self):
        """1 Hz tick while someone is connected; fully asleep otherwise."""
        while True:
            if not self.sessions:
                self._active.clear()
                await self._active.wait()
            await asyncio.sleep(1)
            now = time.monotonic()
            for s in list(self.sessions):
                try:
                    s.tick(now)
                except Exception:
                    log.exception("tick failed")

    async def session_ended(self):
        if self.sessions or not self.x:
            return
        if self._repeat_off:
            self.x.set_autorepeat(True)
            self._repeat_off = False
            try:
                os.unlink(self.repeat_marker)
            except FileNotFoundError:
                pass
        async with self._screen:
            if self.sessions:             # someone connected while we waited
                return
            if not self.login_screen and os.path.exists(self.screen.state_file):
                try:
                    await self.screen.restore()
                except Exception:
                    log.exception("resolution restore failed")

    # ---------------------------------------------------------------- keyboard
    def begin_control(self):
        # Remote key repeat is driven by the client; host auto-repeat on top of network
        # jitter would turn a delayed key-up into a burst of phantom characters.
        if not self._repeat_off and self.x.autorepeat():
            config.write_private(self.repeat_marker, "1\n")
            self.x.set_autorepeat(False)
            self._repeat_off = True

    async def type_text(self, s):
        """Type arbitrary Unicode. Layout characters use their real key; others borrow one of the
        spare keycodes. A repeated character reuses its keycode; once every spare is taken, pause
        so apps consume the earlier keys before a keycode is rebound to something else."""
        x = self.x
        async with self._typing:
            if self._restore_keymap:
                self._restore_keymap.cancel()
            bound, free = {}, x.spare_keycodes
            spares = bool(free)            # none at all: skip what has no key instead of stalling
            for ch in s:
                ks = x._keysym(ch)
                k = x.layout_key(ks)
                if k:
                    x.tap(k[0], k[1], SHIFT_KC)
                    continue
                kc = bound.get(ks)
                if kc is None:
                    if not spares:
                        continue
                    if not free:
                        x.sync()
                        await asyncio.sleep(0.05)
                        bound, free = {}, x.spare_keycodes
                        if not free:
                            continue          # no spare keycodes at all on this server
                    kc = free.pop()
                    x.map_spare(kc, ks)
                    x.sync()
                    bound[ks] = kc
                x.tap(kc, False, SHIFT_KC)
            x.sync()
            self._restore_keymap = self.loop.call_later(0.3, x.restore_keymap)

    # ---------------------------------------------------------------- cursor
    def _on_cursor(self):
        if not self.sessions:
            self.cursor_dirty = True
            return
        if not self._cursor_pending:
            self._cursor_pending = True
            self.loop.call_soon(self._update_cursor)

    def _update_cursor(self):
        self._cursor_pending = False
        self.cursor_dirty = False
        img = self.x.cursor_image()
        if not img or img[5] is None:
            cid = 0
        else:
            serial, w, h, hx, hy, rgba = img
            cid = (zlib.crc32(rgba, zlib.crc32(struct.pack("<HHHH", w, h, hx, hy))) & 0x7FFFFFFF) or 1
            if cid not in self.cursor_cache:
                self.cursor_cache[cid] = {"t": "cur", "id": cid, "w": w, "h": h, "hx": hx, "hy": hy,
                                          "png": _b64(png_rgba(w, h, rgba))}
                while len(self.cursor_cache) > 128:
                    self.cursor_cache.popitem(last=False)
        if cid == self.cursor_id:
            return
        self.cursor_id = cid
        for s in self.sessions:
            s.send_cursor(cid)

    # ---------------------------------------------------------------- clipboard
    def _on_clipboard(self, owner):
        if not self.sessions:          # never read the clipboard when nobody is connected
            self.clip_dirty = True
            return
        if self._clip_task and not self._clip_task.done():
            self._clip_task.cancel()
        self._clip_task = self.loop.create_task(self._read_clipboard())

    async def _read_clipboard(self):
        await asyncio.sleep(0.05)
        text = await self.clip.read()
        if text is None or text == self.clip_text:
            return
        self.clip_text = text
        for s in self.sessions:
            s.ws.send_json({"t": "clip", "text": text})

    async def send_clipboard(self, session):
        if self.clip_dirty:
            self.clip_dirty = False
            self.clip_text = await self.clip.read()
        # Always, even when empty: clients skip the first clip after `ok` as the snapshot.
        session.ws.send_json({"t": "clip", "text": self.clip_text or ""})

    async def set_clipboard(self, text, origin):
        if text == self.clip_text:
            return
        self.clip_text = text
        await self.clip.write(text)
        for s in self.sessions:
            if s is not origin:
                s.ws.send_json({"t": "clip", "text": text})

    # ---------------------------------------------------------------- screen
    def _on_resize(self, w, h):
        for s in self.sessions:
            s.ws.send_json({"t": "screen", "w": w, "h": h})
            if s.cap and s.cap.encoder == "x264":      # ximagesrc keeps its old size: restart it
                s._task(s._stop_capture() if s.paused_at is not None else s._start_capture(restart=True))
        self.loop.create_task(self.refresh_modes(broadcast=True))

    async def refresh_modes(self, send_to=None, broadcast=False):
        if self.login_screen:
            return
        try:
            self.modes = await self.screen.query()
        except Exception as e:
            log.info("xrandr unavailable: %s", e)
            return
        targets = self.sessions if broadcast else ([send_to] if send_to else [])
        for s in targets:
            s.ws.send_json(dict(self.modes, t="modes"))

    async def change_resolution(self, session, m):
        if self.login_screen:
            return
        try:
            async with self._screen:
                if m.get("native"):
                    await self.screen.restore()
                else:
                    await self.screen.set_mode(int(m["w"]), int(m["h"]))
            saved = self._saved_resolutions()
            if m.get("native"):
                saved.pop(_kind(session), None)
            else:
                saved[_kind(session)] = [int(m["w"]), int(m["h"])]
            config.write_private(self.res_file, json.dumps(saved))
        except (ValueError, KeyError, RuntimeError) as e:
            session.ws.send_json({"t": "notice", "level": "error", "text": "resolution change failed: %s" % e})
        await self.refresh_modes(broadcast=True)

    def _saved_resolutions(self):
        try:
            with open(self.res_file) as f:
                saved = json.load(f)
            return saved if isinstance(saved, dict) else {}
        except (OSError, ValueError):
            return {}

    async def restore_resolution(self, session):
        """A device gets back the resolution it chose last time, unless someone else is watching."""
        mode = self._saved_resolutions().get(_kind(session))
        if not mode or self.login_screen:
            return
        try:
            async with self._screen:
                if self.sessions != {session}:
                    return
                await self.screen.set_mode(int(mode[0]), int(mode[1]))
        except (ValueError, TypeError, IndexError, RuntimeError) as e:    # e.g. another monitor now
            log.info("last resolution of %s not restored: %s", _kind(session), e)
            return
        await self.refresh_modes(broadcast=True)

    # ---------------------------------------------------------------- control API
    def status(self):
        return {"sessions": [{"sid": s.sid, "client": s.client, "source": s.source, "user": s.ts_user,
                              "since": int(s.since), "streaming": bool(s.cap and s.paused_at is None),
                              "w": s.w, "h": s.h, "kbps": s.rc.kbps if s.rc else None,
                              "enc": s.cap.encoder if s.cap else None} for s in self.sessions],
                "encoder": self.encoder, "restart_for_gpu": self.cfg["encoder"] != "x264" and capture.driver_restart_needed(),
                "url": self.url, "port": self.cfg["port"],
                "password_set": self.auth.configured}

    def kick(self, sid=None, code=4003, reason="disconnected by host"):
        n = 0
        for s in list(self.sessions):
            if sid is None or s.sid == sid:
                s.kick(code, reason)
                n += 1
        return n
