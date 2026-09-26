"""Remote screen resolution control through xrandr.

A client may switch the host's monitor to a smaller mode (bigger text on a laptop, less
to encode). The original mode is written to disk before the first change and restored
when the last session ends — or on the next daemon start if we crashed in between.
"""
import asyncio
import json
import logging
import os
import re

from . import config

log = logging.getLogger("darpan.screen")

_MODE_RE = re.compile(r"^\s+(\d+)x(\d+)\s+(.*)$")
_OUT_RE = re.compile(r"^(\S+) connected( primary)?(?: (\d+)x(\d+)\+\d+\+\d+)?")


async def _xrandr(display, *args):
    env = dict(os.environ, DISPLAY=display) if display else None
    proc = await asyncio.create_subprocess_exec("xrandr", *args, env=env, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), 10)
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError("xrandr timed out")
    if proc.returncode:
        raise RuntimeError("xrandr %s failed: %s" % (" ".join(args), err.decode(errors="replace").strip()))
    return out.decode(errors="replace")


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

    async def query(self):
        name, current, modes = _parse(await _xrandr(self.display, "--query"))
        seen, lst = set(), []
        for w, h, _ in modes:
            if (w, h) not in seen:
                seen.add((w, h))
                lst.append([w, h])
        lst.sort(key=lambda m: -m[0] * m[1])
        return {"output": name, "current": list(current[:2]) if current else None,
                "native": lst[0] if lst else None, "modes": lst[:24],
                "changed": os.path.exists(self.state_file)}

    async def set_mode(self, w, h):
        name, current, modes = _parse(await _xrandr(self.display, "--query"))
        if not name or not current:
            raise RuntimeError("no active monitor")
        match = [rates for mw, mh, rates in modes if (mw, mh) == (w, h)]
        if not match:
            raise ValueError("mode %dx%d not offered by the monitor" % (w, h))
        rates = [r for rs in match for r in rs]
        # ~60 Hz is plenty for a remote view and lets the compositor do less work.
        rate = min(rates, key=lambda r: abs(r - 60))
        if not os.path.exists(self.state_file):
            config.write_private(self.state_file, json.dumps(
                {"output": name, "w": current[0], "h": current[1], "rate": current[2]}))
        log.info("switching %s to %dx%d@%.2f", name, w, h, rate)
        await _xrandr(self.display, "--output", name, "--mode", "%dx%d" % (w, h), "--rate", "%.2f" % rate)

    async def restore(self):
        try:
            with open(self.state_file) as f:
                orig = json.load(f)
        except FileNotFoundError:
            return
        except Exception:
            os.unlink(self.state_file)
            return
        log.info("restoring %s to %dx%d@%.2f", orig["output"], orig["w"], orig["h"], orig["rate"])
        try:
            await _xrandr(self.display, "--output", orig["output"], "--mode", "%dx%d" % (orig["w"], orig["h"]),
                          "--rate", "%.2f" % orig["rate"])
        except RuntimeError as e:
            log.warning("restore failed: %s", e)
            try:  # fall back to the monitor's preferred mode
                await _xrandr(self.display, "--output", orig["output"], "--auto")
            except RuntimeError:
                return
        os.unlink(self.state_file)
