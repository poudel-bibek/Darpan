"""Remote screen resolution control through xrandr, and with NVIDIA's nvidia-settings, a desktop of any size.

A client may switch the host's monitor to a smaller mode (bigger text on a laptop, less
to encode), or have the desktop fit its window exactly (the monitor keeps its own mode and the GPU
scales the desktop onto it), drawn at GNOME's 100 % or 200 %. The original mode and scale are written
to disk before the first change and restored when the last session ends — or on the next daemon
start if we crashed in between.
"""
import asyncio
import json
import logging
import os
import re
import struct

from . import config

log = logging.getLogger("darpan.screen")

_MODE_RE = re.compile(r"^\s+(\d+)x(\d+)\s+(.*)$")
_OUT_RE = re.compile(r"^(\S+) connected( primary)?(?: (\d+)x(\d+)\+\d+\+\d+)?")
_VMODE_RE = re.compile(r"^\s+(.+?)\s+\((0x[0-9a-f]+)\)\s+([\d.]+)MHz(.*)$")  # xrandr --verbose (any name, spaces too)
_SIZE_RE = re.compile(r"\s(?:width|height)\s+(\d+)\s.*\stotal\s+(\d+)")       # its h: and v: lines
SCALE_KEY = ("org.gnome.desktop.interface", "scaling-factor")   # GNOME on X11: 1 or 2 (0 = automatic)
FIT_SCALES = [100, 125, 150, 175, 200]  # 125-175: GNOME draws at 200 % on a desktop that much bigger,
                                        # and the capture scales it down to the window's size
FIT_MAX = 4096                   # a side, at most: H.264 on NVENC goes no bigger


async def _run(display, *cmd):
    env = dict(os.environ, DISPLAY=display) if display else None
    try:
        proc = await asyncio.create_subprocess_exec(*cmd, env=env, stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.PIPE)
    except FileNotFoundError:
        raise RuntimeError("%s isn't installed" % cmd[0])
    try:
        out, err = await asyncio.wait_for(proc.communicate(), 10)
    except (asyncio.TimeoutError, asyncio.CancelledError) as e:   # (cancelled: the host stopping)
        try:
            proc.kill()
        except ProcessLookupError:           # it had just finished
            pass
        await asyncio.shield(proc.wait())    # its pipes closed while the event loop still runs
        if isinstance(e, asyncio.CancelledError):
            raise
        raise RuntimeError("%s timed out" % cmd[0])
    if proc.returncode:
        raise RuntimeError("%s failed: %s" % (" ".join(cmd), err.decode(errors="replace").strip()))
    return out.decode(errors="replace")


async def _xrandr(display, *args):
    return await _run(display, "xrandr", *args)


def _native(text, output):
    """The monitor's own mode (xrandr marks it "+", NVIDIA's nvidia-auto-select), else the largest offered."""
    on, largest = False, None
    for line in text.splitlines():
        m = _OUT_RE.match(line)
        if m or not line.startswith(" "):
            on = bool(m) and m.group(1) == output
            continue
        mm = _MODE_RE.match(line) if on else None
        if mm:
            wh = (int(mm.group(1)), int(mm.group(2)))
            if "+" in mm.group(3):
                return wh
            largest = max(largest or wh, wh, key=lambda m: m[0] * m[1])
    return largest


def _f32(v):
    return struct.unpack("f", struct.pack("f", v))[0]


def _mutter_modes(verbose, output):
    """The output's modes as GNOME's mutter keeps them, from `xrandr --verbose`: ([(xid, w, h, refresh)], the
    current mode's xid). Mutter (meta-monitor.c, GNOME 46 and later) names a mode WxH@<refresh to 3 decimals>,
    computed in single precision, and keeps one per name: the first listed, unless a later one has exactly the
    flags of the preferred mode (the output's first) and another name than it. A monitor left on a mode it
    dropped has no logical monitor in GNOME, and a click on the top bar then crashes the shell (a laptop panel
    with two 60 Hz modes 0.0001 Hz apart did that)."""
    kept, order, current, mine, preferred = {}, [], None, False, None
    lines = verbose.splitlines()
    for i, line in enumerate(lines):
        m = _OUT_RE.match(line)
        if m or not line.startswith((" ", "\t")):
            mine = bool(m) and m.group(1) == output
            continue
        mm = _VMODE_RE.match(line) if mine else None
        if not mm:
            continue
        xid, rest = mm.group(2), mm.group(4)
        if "*current" in rest:
            current = xid
        hv = [_SIZE_RE.search(l) for l in lines[i + 1:i + 3]]     # the size from these, as mutter takes it, not the
        if len(hv) < 2 or not all(hv):                          # name (a mode added with --newmode has its own)
            continue
        w, h = int(hv[0].group(1)), int(hv[1].group(1))
        ht, vt = float(hv[0].group(2)), float(hv[1].group(2))
        if "DoubleScan" in rest:
            vt *= 2
        if "Interlace" in rest:
            vt /= 2
        refresh = _f32(_f32(round(float(mm.group(3)) * 1e6)) / _f32(_f32(ht) * _f32(vt))) if ht and vt else 0.0
        name = "%dx%d%s@%.3f" % (w, h, "i" if "Interlace" in rest else "", refresh)
        flags = set(rest.split()) - {"*current", "+preferred"}
        if preferred is None:
            preferred = (name, flags)
        if name not in kept:
            order.append(name)
        if name not in kept or (flags == preferred[1] and name != preferred[0]):
            kept[name] = (xid, w, h, refresh)
    return [kept[n] for n in order], current


def _pick(modes, w, h, rate):
    """The xid of the w×h mode mutter keeps whose refresh is nearest rate, or None."""
    sized = [m for m in modes if (m[1], m[2]) == (w, h)]
    return min(sized, key=lambda m: abs(m[3] - rate))[0] if sized else None


async def _switch(display, output, xid, w, h, rate):
    """To the mode by its xid, or by size and rate without one, or when the xid is refused (after the last output,
    `xrandr --verbose` also lists modes attached to none, and one of those can't be set on this output)."""
    if xid:
        try:
            return await _xrandr(display, "--output", output, "--mode", xid, "--transform", "none")
        except RuntimeError as e:
            log.warning("mode %s refused (%s): by size and rate instead", xid, e)
    await _xrandr(display, "--output", output, "--mode", "%dx%d" % (w, h), "--rate", "%.2f" % rate, "--transform", "none")


def _screen_size(text):
    """The desktop's size ("Screen 0: minimum 8 x 8, current 3360 x 2100, …"), or None."""
    m = re.search(r"current (\d+) x (\d+)", text)
    return (int(m.group(1)), int(m.group(2))) if m else None


def _parse(text):
    """-> output name, current (w, h, rate) or None, [(w, h, [rates])] for the primary output."""
    outputs = []
    cur = None
    for line in text.splitlines():
        m = _OUT_RE.match(line)
        if m:
            cur = {"name": m.group(1), "primary": bool(m.group(2)), "modes": [], "current": None}
            outputs.append(cur)
            continue
        if not line.startswith(" "):
            cur = None
            continue
        if cur is None:
            continue
        m = _MODE_RE.match(line)
        if not m:
            continue
        w, h = int(m.group(1)), int(m.group(2))
        rates = []
        for tok in m.group(3).split():
            num = re.match(r"(\d+(?:\.\d+)?)", tok)
            if not num:
                continue
            r = float(num.group(1))
            rates.append(r)
            if "*" in tok:
                cur["current"] = (w, h, r)
        cur["modes"].append((w, h, rates))
    if not outputs:
        return None, None, []
    out = next((o for o in outputs if o["primary"]), outputs[0])
    return out["name"], out["current"], out["modes"]


class Screen:
    def __init__(self, display):
        self.display = display
        self.state_file = os.path.join(config.state_dir(), "screen.json")
        self._fits = None                # can the desktop be any size here (NVIDIA)? Asked once
        self.fitted = None               # [w, h, scale] while a fit is in effect
        self.scaled = None               # (w, h): what the capture scales the desktop to (125-175 %), else None

    async def query(self):
        name, current, modes = _parse(await _xrandr(self.display, "--query"))
        seen, lst = set(), []
        for w, h, _ in modes:
            if (w, h) not in seen:
                seen.add((w, h))
                lst.append([w, h])
        lst.sort(key=lambda m: -m[0] * m[1])
        # "native" = what {"t":"res","native":true} restores: the mode saved before the first
        # remote change, else the current mode (not simply the largest one offered).
        try:
            with open(self.state_file) as f:
                orig = json.load(f)
            native = [orig["w"], orig["h"]]
        except (OSError, ValueError, KeyError):
            native = list(current[:2]) if current else (lst[0] if lst else None)
        out = {"output": name, "current": list(current[:2]) if current else None,
               "native": native, "modes": lst[:24], "changed": os.path.exists(self.state_file)}
        if self._fits is None:
            self._fits = await self._metamode() is not None
        if self._fits:
            out["fit_scales"] = FIT_SCALES
        if self.fitted:
            out["fitted"] = self.fitted
        return out

    async def _metamode(self):
        """NVIDIA's current MetaMode ("DPY-1: 2560x1440_60 @2560x1440 +0+0 {…}"), or None without NVIDIA."""
        try:
            out = await _run(self.display, "nvidia-settings", "-q", "CurrentMetaMode", "-t")
        except RuntimeError:
            return None
        meta = out.strip().split(" :: ", 1)[-1]
        # one display only: a MetaMode names every display, and assigning one with fewer turns the rest off
        # (several monitors is a project of its own)
        return meta if re.match(r"^[\w-]+:", meta) and len(re.findall(r"(?:^|,\s*)[\w-]+:\s", meta)) == 1 else None

    def _remember(self, name, current, **more):
        """Write down what to restore, before the first change; more (e.g. GNOME's scale) when first changed."""
        try:
            with open(self.state_file) as f:
                orig = json.load(f)
        except (OSError, ValueError):
            orig = {"output": name, "w": current[0], "h": current[1], "rate": current[2]}
        for k, v in more.items():
            orig.setdefault(k, v)
        config.write_private(self.state_file, json.dumps(orig))
        return orig

    async def _assign(self, meta, native, w, h):
        """NVIDIA's MetaMode for a w×h desktop, scaled onto the monitor's own mode (as large as fits)."""
        k = min(native[0] / w, native[1] / h)
        ow, oh = int(w * k) // 2 * 2, int(h * k) // 2 * 2
        await _run(self.display, "nvidia-settings", "--assign", "CurrentMetaMode=%s: nvidia-auto-select @%dx%d "
                   "+0+0 {ViewPortIn=%dx%d, ViewPortOut=%dx%d+%d+%d}" % (meta.split(":", 1)[0], w, h, w, h, ow, oh,
                                                                      (native[0] - ow) // 2, (native[1] - oh) // 2))

    async def fit(self, w, h, scale):
        """The desktop as seen exactly w×h, drawn at scale %: 100 and 200 one pixel for one, 125-175 at 200 % on a
        desktop 200/scale times bigger, which the capture scales down to w×h. The monitor keeps its own mode and
        NVIDIA scales the desktop onto it (a MetaMode with ViewPortIn). GNOME reads its scale only when the
        desktop changes size, so the scale is set first, and a desktop that stays the size it is gets a step first."""
        if scale not in FIT_SCALES or not (640 <= w <= 16384 and 480 <= h <= 16384):
            raise ValueError("can't fit %dx%d at %d %%" % (w, h, scale))
        k = min(1.0, FIT_MAX / max(w, h))            # bigger than the encoder takes: both sides down together
        w, h = int(w * k) // 2 * 2, int(h * k) // 2 * 2   # and even (4:2:0); modes' "fitted" says what it made
        if self.fitted == [w, h, scale]:
            log.info("already fitted to %dx%d at %d %%", w, h, scale)   # e.g. a reconnect: no switch, no rearranging
            return
        dw, dh = (w, h) if scale in (100, 200) else (int(w * 200 / scale) // 2 * 2, int(h * 200 / scale) // 2 * 2)
        text = await _xrandr(self.display, "--query")
        name, current, _ = _parse(text)
        native, meta = _native(text, name), await self._metamode()
        if not name or not current or not native or not meta:
            raise RuntimeError("this computer can't fit its desktop to a window (it needs NVIDIA's nvidia-settings)")
        scaling = int((await _run(None, "gsettings", "get", *SCALE_KEY)).split()[-1])
        orig = self._remember(name, current, scaling=scaling)
        want = 1 if scale == 100 else 2
        k = min(native[0] / dw, native[1] / dh)
        ow, oh = int(dw * k) // 2 * 2, int(dh * k) // 2 * 2
        log.info("fitting %s to %dx%d at %d %% (a %dx%d desktop; its own %dx%d shows it %dx%d)",
                 name, w, h, scale, dw, dh, *native, ow, oh)
        await _run(None, "gsettings", "set", *SCALE_KEY, str(want))
        was = self.scaled, self.fitted           # both before the desktop changes (the pointer reads them meanwhile)
        self.scaled, self.fitted = (w, h) if (dw, dh) != (w, h) else None, [w, h, scale]
        try:
            if want != scaling and _screen_size(text) == (dw, dh):  # (else the shell keeps its scale, apps don't:
                await self._assign(meta, native, dw, dh - 2)       # menus come out cut off)
            await self._assign(meta, native, dw, dh)
        except RuntimeError:
            self.scaled, self.fitted = was
            await self._unscale(orig)            # not 200 % on the old desktop
            try:                                 # and the desktop as it was (a step may have changed it)
                await _run(self.display, "nvidia-settings", "--assign", "CurrentMetaMode=" + meta)
            except RuntimeError as e:
                log.warning("desktop not put back: %s", e)
            raise

    async def _unscale(self, orig):
        """GNOME's own scale again, before a mode change makes it read it."""
        if "scaling" in orig:
            try:
                await _run(None, "gsettings", "set", *SCALE_KEY, str(orig["scaling"]))
            except RuntimeError as e:
                log.warning("GNOME's scale not restored: %s", e)

    async def _step(self, text, w, h):
        """Before a mode change that leaves a fitted desktop the size it is: a step to another size, so GNOME
        reads the scale just put back (it reads it only when the desktop changes size)."""
        if _screen_size(text) == (w, h):
            name = _parse(text)[0]
            native, meta = _native(text, name), await self._metamode()
            if native and meta:
                await self._assign(meta, native, w, h - 2)

    async def set_mode(self, w, h):
        text = await _xrandr(self.display, "--query")
        name, current, modes = _parse(text)
        if not name or not current:
            raise RuntimeError("no active monitor")
        match = [rates for mw, mh, rates in modes if (mw, mh) == (w, h)]
        if not match:
            raise ValueError("mode %dx%d not offered by the monitor" % (w, h))
        rates = [r for rs in match for r in rs]
        # ~60 Hz is plenty for a remote view and lets the compositor do less work.
        rate = min(rates, key=lambda r: abs(r - 60))
        vmodes, vcurrent = _mutter_modes(await _xrandr(self.display, "--verbose"), name)
        xid = _pick(vmodes, w, h, rate)          # the one GNOME knows, of modes alike to a thousandth of a Hz
        if not self.fitted and (xid == vcurrent if xid else (w, h) == tuple(current[:2]) and abs(rate - current[2]) < 0.05):
            log.info("%s already at %dx%d@%.2f", name, w, h, rate)   # e.g. a reconnect before the old mode came back
            return
        orig = self._remember(name, current)
        if self.fitted:
            await self._unscale(orig)
            await self._step(text, w, h)
        self.scaled = None
        log.info("switching %s to %dx%d@%.2f (%s)", name, w, h, rate, xid)
        await _switch(self.display, name, xid, w, h, rate)   # (--transform none: a fit's scaling, if there was one)
        self.fitted = None

    async def restore(self):
        try:
            with open(self.state_file) as f:
                orig = json.load(f)
        except FileNotFoundError:
            return
        except Exception:
            os.unlink(self.state_file)
            return
        await self._unscale(orig)
        self.scaled = None
        try:
            if "scaling" in orig:                # it was fitted
                await self._step(await _xrandr(self.display, "--query"), orig["w"], orig["h"])
            xid = _pick(_mutter_modes(await _xrandr(self.display, "--verbose"), orig["output"])[0],
                        orig["w"], orig["h"], orig["rate"])
            log.info("restoring %s to %dx%d@%.2f (%s)", orig["output"], orig["w"], orig["h"], orig["rate"], xid)
            await _switch(self.display, orig["output"], xid, orig["w"], orig["h"], orig["rate"])
        except RuntimeError as e:
            log.warning("restore failed: %s", e)
            try:  # fall back to the monitor's preferred mode
                await _xrandr(self.display, "--output", orig["output"], "--auto", "--transform", "none")
            except RuntimeError:
                return
        self.fitted = None
        os.unlink(self.state_file)
