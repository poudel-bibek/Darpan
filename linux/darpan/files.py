"""File browsing and transfers for viewers (PROTOCOL.md §7.1): plain HTTP requests under /fs/,
authorized by a token that lives as long as its session, or by a single-use ticket for browser
downloads. Disk work and directory scans run on worker threads, so a slow disk never delays
video or input."""
import asyncio
import email.utils
import errno
import json
import logging
import os
import secrets
import stat
import time
from urllib.parse import parse_qs, quote

log = logging.getLogger("darpan.files")

MAX_ENTRIES = 20000          # one directory
MAX_DEEP = 50000             # a whole folder (deep=1)
MAX_ACTIVE = 4               # requests at once per session
MAX_TICKETS = 64             # live tickets per session
TICKET_TTL = 60              # s
CHUNK = 256 * 1024
STALL = 60                   # s without progress ends a transfer
_ROUTES = {("GET", "/fs/list"), ("GET", "/fs/file"), ("HEAD", "/fs/file"), ("PUT", "/fs/file"),
           ("POST", "/fs/mkdir"), ("POST", "/fs/ticket")}
_STATUS = {200: "OK", 201: "Created", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized",
           403: "Forbidden", 404: "Not Found", 409: "Conflict", 416: "Range Not Satisfiable",
           429: "Too Many Requests", 500: "Internal Server Error", 507: "Insufficient Storage"}


class Error(Exception):
    """An answer from §7.1's error list."""

    def __init__(self, status, code):
        super().__init__(code)
        self.status, self.code = status, code


class _Gone(Exception):
    """The client went away or stalled mid-transfer: nothing more can be said to it."""


def _oserror(e):
    if isinstance(e, FileNotFoundError):
        return Error(404, "notfound")
    if isinstance(e, NotADirectoryError):
        return Error(409, "notdir")
    if isinstance(e, IsADirectoryError):
        return Error(409, "isdir")
    if isinstance(e, FileExistsError):
        return Error(409, "exists")
    if isinstance(e, PermissionError):
        return Error(403, "denied")
    if e.errno in (errno.ENOSPC, errno.EDQUOT):
        return Error(507, "nospace")
    if e.errno == errno.ENXIO:                  # a Unix socket can't be opened
        return Error(409, "notfile")
    log.warning("file request failed: %s", e)
    return Error(500, "failed")


def _query(query):
    try:
        q = parse_qs(query, keep_blank_values=True, errors="strict", max_num_fields=8)
    except (UnicodeDecodeError, ValueError):
        raise Error(400, "invalid") from None
    return {k: v[0] for k, v in q.items()}


def _path(q):
    p = q.get("path", "")
    if not p.startswith("/") or "\0" in p:
        raise Error(400, "invalid")
    return p


def _head(status, fields, keep):
    lines = ["HTTP/1.1 %d %s" % (status, _STATUS[status]), *fields, "Cache-Control: no-store",
             "X-Content-Type-Options: nosniff", "Connection: " + ("keep-alive" if keep else "close")]
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def _json(writer, status, obj, keep, fields=()):
    body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
    writer.write(_head(status, ["Content-Type: application/json", "Content-Length: %d" % len(body), *fields], keep) + body)


# ---------------------------------------------------------------- on worker threads

def _utf8(name):
    try:
        name.encode()
        return True
    except UnicodeEncodeError:                  # undecodable bytes (surrogate escapes)
        return False


def _entry(name, de):
    try:
        st = de.stat()                          # follows links: the type is the target's
        kind = "d" if stat.S_ISDIR(st.st_mode) else "f" if stat.S_ISREG(st.st_mode) else "o"
        size, mtime = (st.st_size if kind == "f" else 0), int(st.st_mtime)
    except OSError:                             # a dangling link
        kind, size, mtime = "o", 0, 0
    return {"name": name, "type": kind, "size": size, "mtime": mtime, "link": de.is_symlink()}


def _scan(p):
    out, more = [], False
    with os.scandir(p) as it:
        for de in it:
            if not _utf8(de.name):
                continue
            if len(out) >= MAX_ENTRIES:
                more = True
                break
            out.append(_entry(de.name, de))
    out.sort(key=lambda e: (e["type"] != "d", e["name"].casefold()))
    return out, more


def _scan_deep(p):
    """Everything below p, a directory before its contents; links to directories aren't followed."""
    out, stack = [], [(p, "")]
    while stack:
        d, rel = stack.pop()
        try:
            with os.scandir(d) as it:
                items = sorted(((de.name, de) for de in it if _utf8(de.name)), key=lambda x: x[0].casefold())
        except OSError:
            if d == p:
                raise
            continue                            # an unreadable subfolder is listed, without contents
        subdirs = []
        for name, de in items:
            if len(out) >= MAX_DEEP:
                return out, True
            e = _entry(rel + name, de)
            out.append(e)
            if e["type"] == "d" and not e["link"]:
                subdirs.append((os.path.join(d, name), rel + name + "/"))
        stack.extend(reversed(subdirs))
    return out, False


def _open_regular(p):
    # O_NONBLOCK: opening a pipe must not wait for a writer (it's refused right after)
    fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if stat.S_ISDIR(st.st_mode):
            raise Error(409, "isdir")
        if not stat.S_ISREG(st.st_mode):
            raise Error(409, "notfile")
        return fd, st
    except BaseException:
        os.close(fd)
        raise


def _regular(p):
    st = os.stat(p)
    if stat.S_ISDIR(st.st_mode):
        raise Error(409, "isdir")
    if not stat.S_ISREG(st.st_mode):
        raise Error(409, "notfile")


def _prepare_put(p, mode):
    """Checks the target before any byte is read, then opens a hidden temporary file next to it."""
    d = os.path.dirname(p)
    if not stat.S_ISDIR(os.stat(d).st_mode):
        raise Error(409, "notdir")
    try:
        st = os.stat(p)
    except FileNotFoundError:
        st = None
    if st and mode != "rename":
        if stat.S_ISDIR(st.st_mode):
            raise Error(409, "isdir")
        if mode == "fail":
            raise Error(409, "exists")
    tmp = os.path.join(d, ".darpan-upload-%s.part" % secrets.token_hex(6))
    return os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o666), tmp


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


def _place(tmp, p, mode):
    """Moves the finished upload to p (or, with rename, the first free `name (n).ext`)."""
    if mode == "replace":
        os.replace(tmp, p)
        return p
    d, name = os.path.split(p)
    base, ext = os.path.splitext(name)
    cand, n = p, 0
    while True:
        try:
            os.link(tmp, cand)                  # never overwrites: fails if cand exists
            os.unlink(tmp)
            return cand
        except FileExistsError:
            pass
        except OSError as e:
            if e.errno not in (errno.EPERM, errno.EOPNOTSUPP, errno.EMLINK):
                raise
            if not os.path.lexists(cand):       # no hard links here (FAT, some FUSE): check, then rename
                os.rename(tmp, cand)
                return cand
        if mode == "fail":
            raise Error(409, "exists")
        n += 1
        cand = os.path.join(d, "%s (%d)%s" % (base, n, ext))


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _range(value, size):
    """(start, end) of a `bytes=N-` or `bytes=N-M` range, or None to send the whole file."""
    if not value.startswith("bytes=") or "," in value:
        return None
    a, sep, b = value[6:].strip().partition("-")
    if not sep or not a.isdigit() or (b and not b.isdigit()):
        return None
    start, end = int(a), (int(b) if b else size - 1)
    if start >= size or end < start:
        raise Error(416, "range")
    return start, min(end, size - 1)


def _disposition(p):
    name = os.path.basename(p)
    plain = "".join(c if 32 <= ord(c) < 127 and c not in '"\\' else "_" for c in name) or "file"
    return "Content-Disposition: attachment; filename=\"%s\"; filename*=UTF-8''%s" % (plain, quote(name, safe=""))


# ---------------------------------------------------------------- the service

class Files:
    def __init__(self, hub):
        self.hub = hub
        self.tokens = {}         # token -> session
        self.tickets = {}        # ticket -> (session, path, expiry)
        self.active = {}         # session -> writers of its requests in progress

    def hello(self, session, inbox):
        """The answer to {"t":"fs"}: the session's token (made once) and where things are."""
        token = next((t for t, s in self.tokens.items() if s is session), None)
        if token is None:
            token = secrets.token_urlsafe(32)
            self.tokens[token] = session
        try:
            os.makedirs(inbox, exist_ok=True)
        except OSError:
            pass
        return {"t": "fs", "token": token, "home": os.path.expanduser("~"), "inbox": inbox}

    def forget(self, session):
        """The session ended: its token and tickets stop working, and its transfers stop now."""
        for t in [t for t, s in self.tokens.items() if s is session]:
            del self.tokens[t]
        for t in [t for t, v in self.tickets.items() if v[0] is session]:
            del self.tickets[t]
        for w in self.active.pop(session, ()):
            w.transport.abort()

    def _session(self, authorization):
        scheme, _, token = authorization.partition(" ")
        s = self.tokens.get(token.strip()) if scheme.lower() == "bearer" else None
        if s is None or s not in self.hub.sessions:
            raise Error(401, "token")
        return s

    def _ticket_for(self, ticket):
        v = self.tickets.get(ticket)
        if v is None or v[2] < time.monotonic() or v[0] not in self.hub.sessions:
            raise Error(401, "token")
        return v[0], v[1]

    async def _run(self, fn, *args):
        try:
            return await asyncio.get_running_loop().run_in_executor(None, fn, *args)
        except OSError as e:
            raise _oserror(e) from None

    async def handle(self, reader, writer, method, path, query, headers, origin_ok):
        """One request under /fs/. Returns whether the connection can take another one."""
        keep = headers.get("connection", "").lower() != "close"
        length = headers.get("content-length", "0")
        body = int(length) if length.isdigit() else -1
        consumed = method != "PUT" and body == 0
        try:
            try:
                if (method, path) not in _ROUTES:
                    raise Error(404, "notfound")
                if not origin_ok:
                    raise Error(403, "denied")
                if body < 0 or "transfer-encoding" in headers:
                    raise Error(400, "invalid")
                q = _query(query)
                attach = method == "GET" and path == "/fs/file" and "ticket" in q
                if attach:
                    session, p = self._ticket_for(q["ticket"])
                else:
                    session, p = self._session(headers.get("authorization", "")), _path(q)
                if method != "PUT" and body:            # no body expected: a small one is read and dropped
                    if body > 65536:
                        raise Error(400, "invalid")
                    await asyncio.wait_for(reader.readexactly(body), STALL)
                    consumed = True
                active = self.active.setdefault(session, set())
                if len(active) >= MAX_ACTIVE:
                    raise Error(429, "busy")
                if attach:
                    del self.tickets[q["ticket"]]       # single use
                active.add(writer)
                try:
                    if path == "/fs/list":
                        entries, more = await self._run(_scan_deep if q.get("deep") == "1" else _scan, p)
                        _json(writer, 200, {"path": p, "entries": entries, "more": more}, keep)
                    elif method == "PUT":
                        mode = q.get("exists", "fail")
                        if mode not in ("fail", "replace", "rename") or not os.path.basename(p):
                            raise Error(400, "invalid")
                        final = await self._put(reader, p, mode, body)
                        consumed = True
                        _json(writer, 201, {"path": final}, keep)
                    elif path == "/fs/file":
                        await self._get(writer, p, method, headers, attach, keep)
                    elif path == "/fs/mkdir":
                        await self._run(os.mkdir, p)
                        _json(writer, 201, {"path": p}, keep)
                    else:
                        _json(writer, 200, await self._ticket(session, p), keep)
                    await asyncio.wait_for(writer.drain(), STALL)
                finally:
                    active.discard(writer)
                    if not active and self.active.get(session) is active:
                        del self.active[session]
            except (ConnectionError, asyncio.TimeoutError, asyncio.IncompleteReadError):
                raise _Gone() from None
        except Error as e:
            keep = keep and consumed            # an unread body can't be skipped: close instead
            _json(writer, e.status, {"e": e.code}, keep, ["WWW-Authenticate: Bearer"] if e.status == 401 else [])
            return keep
        except _Gone:
            return False
        return keep

    async def _get(self, writer, p, method, headers, attach, keep):
        fd, st = await self._run(_open_regular, p)
        try:
            size = st.st_size
            etag = '"%x-%x-%x"' % (st.st_ino, size, st.st_mtime_ns)
            start, end, status = 0, size - 1, 200
            rng = headers.get("range")
            if rng and headers.get("if-range", etag) == etag:    # changed since: the whole file again
                try:
                    r = _range(rng, size)
                except Error:
                    _json(writer, 416, {"e": "range"}, keep, ["Content-Range: bytes */%d" % size])
                    return
                if r:
                    (start, end), status = r, 206
            fields = ["Content-Type: application/octet-stream", "Content-Length: %d" % (end - start + 1),
                      "ETag: " + etag, "Last-Modified: " + email.utils.formatdate(st.st_mtime, usegmt=True),
                      "Accept-Ranges: bytes"]
            if status == 206:
                fields.append("Content-Range: bytes %d-%d/%d" % (start, end, size))
            if attach:
                fields.append(_disposition(p))
            writer.write(_head(status, fields, keep))
            if method == "HEAD":
                return
            pos = start
            while pos <= end:
                try:
                    data = await self._run(os.pread, fd, min(CHUNK, end - pos + 1), pos)
                except Error:
                    raise _Gone() from None     # the head is out: all that's left is to hang up
                if not data:                    # the file shrank meanwhile: the client sees a short body
                    raise _Gone()
                writer.write(data)
                await asyncio.wait_for(writer.drain(), STALL)
                pos += len(data)
        finally:
            os.close(fd)

    async def _put(self, reader, p, mode, size):
        fd, tmp = await self._run(_prepare_put, p, mode)
        done = False
        try:
            left = size
            while left:
                buf = bytearray()
                while left and len(buf) < CHUNK:
                    chunk = await asyncio.wait_for(reader.read(min(CHUNK - len(buf), left)), STALL)
                    if not chunk:
                        raise _Gone()           # cut short: the temporary file goes
                    buf += chunk
                    left -= len(chunk)
                await self._run(_write_all, fd, buf)
            os.close(fd)
            fd = None
            final = await self._run(_place, tmp, p, mode)
            done = True
            return final
        finally:
            if fd is not None:
                os.close(fd)
            if not done:
                _unlink(tmp)                    # here, not on a thread: it must happen even when cancelled

    async def _ticket(self, session, p):
        await self._run(_regular, p)
        now = time.monotonic()
        for t in [t for t, v in self.tickets.items() if v[2] < now]:
            del self.tickets[t]
        mine = [t for t, v in self.tickets.items() if v[0] is session]
        if len(mine) >= MAX_TICKETS:
            del self.tickets[mine[0]]           # the oldest
        ticket = secrets.token_urlsafe(32)
        self.tickets[ticket] = (session, p, now + TICKET_TTL)
        return {"ticket": ticket}
