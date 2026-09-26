"""Text clipboard bridge. Change detection is event-driven (XFixes owner-change events
arrive on the X11 connection), so nothing polls; xclip does the selection protocol."""
import asyncio
import logging
import os

log = logging.getLogger("darpan.clip")
MAX = 1 << 20


async def _reap(p):
    try:
        p.kill()
    except ProcessLookupError:
        pass
    await p.wait()


class Clipboard:
    def __init__(self, display):
        self.env = dict(os.environ, DISPLAY=display) if display else None

    async def read(self):
        try:
            p = await asyncio.create_subprocess_exec(
                "xclip", "-o", "-selection", "clipboard", "-t", "UTF8_STRING", env=self.env,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(p.communicate(), 2)
        except asyncio.TimeoutError:
            await _reap(p)
            return None
        except (FileNotFoundError, OSError):
            return None
        if p.returncode or len(out) > MAX:
            return None
        return out.decode("utf-8", errors="replace")

    async def write(self, text):
        try:
            # xclip forks a child that serves the selection until someone else takes it.
            p = await asyncio.create_subprocess_exec(
                "xclip", "-i", "-selection", "clipboard", "-t", "UTF8_STRING", env=self.env,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
            await asyncio.wait_for(p.communicate(text.encode()), 3)
        except asyncio.TimeoutError:
            await _reap(p)
            log.warning("clipboard write timed out")
        except (FileNotFoundError, OSError) as e:
            log.warning("clipboard write failed: %s", e)
