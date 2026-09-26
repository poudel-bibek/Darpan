"""Local control socket for the status window and CLI. A Unix socket in the user's
runtime dir (mode 0600): only this user can see sessions or disconnect them."""
import asyncio
import json
import os
import socket

from . import config

PATH = os.path.join(config.runtime_dir(), "control.sock")


async def serve(hub):
    try:
        os.unlink(PATH)
    except FileNotFoundError:
        pass
    old = os.umask(0o177)
    try:
        srv = await asyncio.start_unix_server(lambda r, w: _client(hub, r, w), path=PATH)
    finally:
        os.umask(old)
    return srv


async def _client(hub, reader, writer):
    try:
        req = json.loads(await asyncio.wait_for(reader.readline(), 5) or b"{}")
        cmd = req.get("cmd")
        if cmd == "status":
            resp = hub.status()
        elif cmd == "kick":
            resp = {"kicked": hub.kick(req.get("sid"))}
        elif cmd == "reload":
            hub.auth.reload()
            resp = {"ok": True}
        else:
            resp = {"error": "unknown command"}
        writer.write(json.dumps(resp).encode() + b"\n")
        await writer.drain()
    except Exception:
        pass
    finally:
        writer.close()


def request(cmd, **kw):
    """Synchronous client. Raises OSError if the daemon isn't running."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(PATH)
        s.sendall(json.dumps(dict(kw, cmd=cmd)).encode() + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        return json.loads(data or b"{}")
    finally:
        s.close()
