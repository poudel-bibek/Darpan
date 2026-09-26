"""HTTP/1.1 + WebSocket (RFC 6455) server on asyncio — standard library only.

Only four kinds of request exist: the web client's static files (held in memory,
pre-gzipped), GET /api/info, the /ws and /audio WebSockets, and file requests under /fs/
(files.py). Everything else is refused early.
"""
import asyncio
import base64
import gzip
import hashlib
import ipaddress
import json
import logging
import os
import socket
import struct
import time
from urllib.parse import urlsplit

from . import config

log = logging.getLogger("darpan.web")

_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_HEADER = 16 * 1024
MAX_TEXT = 2 << 20
MAX_BINARY = 8 << 20

_CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; "
        "connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
_SECURITY = ("Content-Security-Policy: %s\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
             "X-Frame-Options: DENY\r\nCross-Origin-Opener-Policy: same-origin\r\n"
             "Permissions-Policy: camera=(), microphone=(), geolocation=()\r\n") % _CSP
_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
          ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
          ".webmanifest": "application/manifest+json", ".json": "application/json"}
_TS_V4 = ipaddress.ip_network("100.64.0.0/10")
_TS_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")


class Static:
    """Web client files, loaded once. In dev mode (DARPAN_DEV=1) re-read on change."""

    def __init__(self, root):
        self.root = root
        self.dev = bool(os.environ.get("DARPAN_DEV"))
        self.files = {}
        self._load()

    def _load(self):
        files = {}
        if os.path.isdir(self.root):
            for name in os.listdir(self.root):
                p = os.path.join(self.root, name)
                ext = os.path.splitext(name)[1]
                if os.path.isfile(p) and ext in _TYPES:
                    with open(p, "rb") as f:
                        data = f.read()
                    gz = gzip.compress(data, 9, mtime=0) if len(data) > 1024 else None
                    etag = '"%s"' % hashlib.sha256(data).hexdigest()[:20]
                    files[name] = (data, gz, _TYPES[ext], etag, os.path.getmtime(p))
        self.files = files

    def get(self, name):
        if self.dev:
            ent = self.files.get(name)
            p = os.path.join(self.root, name)
            if ent is None or not os.path.exists(p) or os.path.getmtime(p) != ent[4]:
                self._load()
        return self.files.get(name)


def _unmask(data, mask):
    n = len(data)
    if not n:
        return b""
    m = int.from_bytes((mask * ((n >> 2) + 1))[:n], "little")
    return (int.from_bytes(data, "little") ^ m).to_bytes(n, "little")


class WebSocket:
    def __init__(self, reader, writer):
        self.r = reader
        self.w = writer
        self.transport = writer.transport
        self.closed = False
        self.last_rx = time.monotonic()   # any frame (pongs too) proves the peer is alive

    @property
    def buffered(self):
        return self.transport.get_write_buffer_size()

    async def recv(self):
        """Next message as (is_text, bytes), or None once the connection is gone."""
        parts, op0, total = [], None, 0
        try:
            while True:
                b0, b1 = await self.r.readexactly(2)
                self.last_rx = time.monotonic()
                fin, op, n = b0 & 0x80, b0 & 0x0F, b1 & 0x7F
                if b0 & 0x70 or not b1 & 0x80:          # RSV bits set / client frame not masked
                    return self._fail(1002)
                if n == 126:
                    n = struct.unpack(">H", await self.r.readexactly(2))[0]
                elif n == 127:
                    n = struct.unpack(">Q", await self.r.readexactly(8))[0]
                if op >= 8:
                    if n > 125 or not fin:
                        return self._fail(1002)
                else:
                    kind = op0 if op == 0 else op
                    if kind not in (1, 2) or (op == 0) != (op0 is not None):
                        return self._fail(1002)
                    total += n
                    if total > (MAX_TEXT if kind == 1 else MAX_BINARY):
                        return self._fail(1009)
                mask = await self.r.readexactly(4)
                data = _unmask(await self.r.readexactly(n), mask) if n else b""
                if op == 8:
                    self._frame(8, data[:2])
                    self.closed = True
                    self.w.close()
                    return None
                if op == 9:
                    self._frame(10, data)
                    continue
                if op == 10:
                    continue
                if op0 is None:
                    op0 = op
                parts.append(data)
                if fin:
                    return op0 == 1, parts[0] if len(parts) == 1 else b"".join(parts)
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            self.closed = True
            return None

    def _fail(self, code):
        self.close(code)
        return None

    def _frame(self, op, *parts):
        if self.closed or self.transport.is_closing():
            return
        n = 0
        for p in parts:
            n += len(p)
        if n < 126:
            hdr = bytes((0x80 | op, n))
        elif n < 65536:
            hdr = struct.pack(">BBH", 0x80 | op, 126, n)
        else:
            hdr = struct.pack(">BBQ", 0x80 | op, 127, n)
        self.w.writelines((hdr,) + parts)     # scatter-gather: no concatenation copies

    def send_text(self, s):
        self._frame(1, s.encode())

    def send_json(self, obj):
        self._frame(1, json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode())

    def send_binary(self, *parts):
        self._frame(2, *parts)

    def ping(self):
        self._frame(9, b"")

    def close(self, code=1000, reason=""):
        if self.closed:
            return
        self._frame(8, struct.pack(">H", code) + reason.encode()[:120])
        self.closed = True
        loop = asyncio.get_running_loop()
        loop.call_later(0.5, self.w.close)
        # close() waits for the send buffer to drain, which a dead peer never lets happen
        loop.call_later(3, self.transport.abort)

    def abort(self):
        """Drop the connection now, without a closing handshake (the peer stopped answering)."""
        self.closed = True
        self.transport.abort()


def _host_allowed(host):
    """Defeat DNS rebinding: only names this machine is actually reached by."""
    if not host:
        return False
    h = host.lower()
    if h.startswith("["):
        h = h[1:h.find("]")] if "]" in h else h
    elif h.count(":") == 1:
        h = h.split(":", 1)[0]
    if h in ("localhost", config.hostname().lower(), config.hostname().lower() + ".local"):
        return True
    if h.endswith(".ts.net") or h.endswith(".localhost"):
        return True
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        return False
    return ip.is_loopback or ip in _TS_V4 or ip in _TS_V6


def _origin_allowed(headers):
    """Browsers always send an Origin on these requests (native clients send none): it must be us."""
    origin = headers.get("origin")
    if origin is None:
        return True
    o = urlsplit(origin).netloc.lower()
    allowed = {h for h in (headers.get("host", "").lower(), headers.get("x-forwarded-host", "").lower()) if h}
    return bool(o) and o in allowed        # rejects "null" (sandboxed iframes, data: URLs) too


class Server:
    def __init__(self, hub, cfg):
        self.hub = hub
        self.cfg = cfg
        self.static = Static(config.WEB_DIR)
        self.srv = None

    async def start(self):
        # Installed, systemd (darpan.socket) owns the listening socket for the whole login and
        # hands it over (sd_listen_fds): no other local user can take the port while we restart,
        # and Tailscale (BindsTo=darpan.socket) never forwards to a port we don't hold.
        if os.environ.get("LISTEN_PID") == str(os.getpid()) and os.environ.get("LISTEN_FDS") == "1":
            sock = socket.socket(fileno=3)
            for k in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"):
                os.environ.pop(k, None)          # don't leak them to children
            self.srv = await asyncio.start_server(self._conn, sock=sock, limit=MAX_HEADER)
            # The unit decides the port; everything else (status, Tailscale Serve) follows it.
            self.cfg["port"] = sock.getsockname()[1]
            log.info("listening on %s:%d (socket from systemd)", *sock.getsockname()[:2])
            return
        self.srv = await asyncio.start_server(self._conn, self.cfg["bind"], self.cfg["port"],
                                              limit=MAX_HEADER, reuse_address=True, backlog=64)
        log.info("listening on http://%s:%d", self.cfg["bind"], self.cfg["port"])

    async def close(self):
        if self.srv:
            self.srv.close()

    async def _conn(self, reader, writer):
        sock = writer.get_extra_info("socket")
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        peer = (writer.get_extra_info("peername") or ("?",))[0]
        try:
            first = True
            while True:
                req = await asyncio.wait_for(self._read_request(reader), 15 if first else 75)
                first = False
                if req is None:
                    break
                method, path, query, headers = req
                if not _host_allowed(headers.get("host")):
                    self._simple(writer, 421, "Misdirected Request")
                    break
                if path in ("/ws", "/audio"):
                    await self._websocket(reader, writer, peer, headers, path)
                    return
                if path.startswith("/fs/"):
                    if not await self.hub.files.handle(reader, writer, method, path, query, headers,
                                                       _origin_allowed(headers)):
                        break
                    continue
                keep = self._respond(writer, method, path, headers)
                await writer.drain()
                if not keep:
                    break
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError,
                asyncio.LimitOverrunError, OSError):
            pass
        except Exception:
            log.exception("connection handler failed")
        finally:
            if not writer.is_closing():
                writer.close()

    async def _read_request(self, reader):
        try:
            head = await reader.readuntil(b"\r\n\r\n")
        except asyncio.IncompleteReadError as e:
            if e.partial.strip():
                raise ValueError("truncated request")
            return None
        lines = head.decode("latin-1").split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3 or not parts[2].startswith("HTTP/1."):
            raise ValueError("bad request line")
        headers = {}
        for line in lines[1:]:
            if line:
                k, sep, v = line.partition(":")
                if not sep:
                    raise ValueError("bad header")
                headers[k.strip().lower()] = v.strip()
        if len(headers) > 64:
            raise ValueError("too many headers")
        path, _, query = parts[1].partition("?")
        return parts[0], path, query, headers

    def _simple(self, writer, code, text, extra=""):
        body = text.encode()
        writer.write(("HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n%s"
                      "Connection: close\r\n\r\n" % (code, text, len(body), extra)).encode() + body)

    def _respond(self, writer, method, path, headers):
        if method not in ("GET", "HEAD"):
            self._simple(writer, 405, "Method Not Allowed", "Allow: GET, HEAD\r\n")
            return False
        keep = headers.get("connection", "").lower() != "close"
        if path == "/api/info":
            body = json.dumps(self.hub.info()).encode()
            ctype, etag, enc = "application/json", None, None
        else:
            name = "index.html" if path in ("/", "/index.html") else path.lstrip("/")
            ent = self.static.get(name) if "/" not in name else None
            if not ent:
                self._simple(writer, 404, "Not Found")
                return False
            data, gz, ctype, etag, _ = ent
            if headers.get("if-none-match") == etag:
                writer.write(("HTTP/1.1 304 Not Modified\r\nETag: %s\r\n\r\n" % etag).encode())
                return keep
            use_gz = gz is not None and "gzip" in headers.get("accept-encoding", "")
            body, enc = (gz, "gzip") if use_gz else (data, None)
        head = ["HTTP/1.1 200 OK", "Content-Type: " + ctype, "Content-Length: %d" % len(body),
                "Cache-Control: no-cache"]
        if etag:
            head.append("ETag: " + etag)
        if enc:
            head += ["Content-Encoding: " + enc, "Vary: Accept-Encoding"]
        head.append("Connection: " + ("keep-alive" if keep else "close"))
        writer.write(("\r\n".join(head) + "\r\n" + _SECURITY + "\r\n").encode())
        if method == "GET":
            writer.write(body)
        return keep

    async def _websocket(self, reader, writer, peer, headers, path):
        key = headers.get("sec-websocket-key", "")
        if (headers.get("upgrade", "").lower() != "websocket" or "upgrade" not in headers.get("connection", "").lower()
                or headers.get("sec-websocket-version") != "13" or len(key) != 24):
            self._simple(writer, 400, "Bad Request")
            return writer.close()
        if not _origin_allowed(headers):
            log.warning("rejected WebSocket from origin %s", headers.get("origin"))
            self._simple(writer, 403, "Forbidden")
            return writer.close()
        accept = base64.b64encode(hashlib.sha1(key.encode() + _GUID).digest()).decode()
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        # Behind Tailscale Serve every peer is 127.0.0.1; the real client is in X-Forwarded-For.
        source = peer
        xff = headers.get("x-forwarded-for")
        try:
            if xff and ipaddress.ip_address(peer).is_loopback:
                source = xff.split(",")[0].strip()[:64]
        except ValueError:
            pass
        ws = WebSocket(reader, writer)
        if path == "/audio":
            await self.hub.handle_audio(ws, source)
        else:
            await self.hub.handle(ws, source, headers)
