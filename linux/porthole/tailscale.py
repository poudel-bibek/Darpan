"""The bundled Tailscale: tailscaled runs as its own user service (porthole-net.service)
in userspace-networking mode — no root, no firewall changes, no TUN device. We talk to its
LocalAPI (JSON over the unix socket) directly, so the 33 MB `tailscale` CLI isn't shipped."""
import http.client
import json
import os
import socket
import time

from . import config

SOCKET = os.path.join(config.runtime_dir(), "tailscaled.sock")


class Error(Exception):
    pass


class _Conn(http.client.HTTPConnection):
    def __init__(self, timeout):
        super().__init__("local-tailscaled.sock", timeout=timeout)

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(SOCKET)
        self.sock = s


def api(method, path, body=None, timeout=10):
    c = _Conn(timeout)
    try:
        headers = {"Sec-Tailscale": "localapi"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        c.request(method, "/localapi/v0/" + path, body=data, headers=headers)
        r = c.getresponse()
        out = r.read()
    finally:
        c.close()
    if r.status >= 400:
        raise Error("%s %s: %d %s" % (method, path, r.status, out.decode(errors="replace").strip()))
    if out[:1] in (b"{", b"["):
        return json.loads(out)
    return out


def status():
    """LocalAPI status (same as `tailscale status --json`), or None if tailscaled is down."""
    try:
        return api("GET", "status", timeout=5)
    except (OSError, Error, ValueError):
        return None


def summary():
    st = status()
    if st is None:
        return {"state": "stopped"}
    me = st.get("Self") or {}
    dns = (me.get("DNSName") or "").rstrip(".")
    user = ((st.get("User") or {}).get(str(me.get("UserID", ""))) or {}).get("LoginName")
    peers = [{"name": (p.get("DNSName") or p.get("HostName") or "").rstrip("."), "os": p.get("OS"),
              "online": p.get("Online"), "direct": bool(p.get("CurAddr")), "relay": p.get("Relay")}
             for p in (st.get("Peer") or {}).values()]
    return {"state": st.get("BackendState", "?"), "dns": dns or None, "url": ("https://" + dns) if dns else None,
            "ips": me.get("TailscaleIPs") or [], "auth_url": st.get("AuthURL") or None,
            "tailnet": (st.get("CurrentTailnet") or {}).get("Name"), "user": user, "peers": peers,
            "https": _has_https(me)}


def _has_https(me):
    caps = set(me.get("Capabilities") or []) | set((me.get("CapMap") or {}).keys())
    return "https" in caps


def login(hostname=None, wait=20):
    """Begin interactive sign-in. Returns the https://login.tailscale.com/... URL the user must
    open, or None when already signed in. Completes in the background once approved."""
    prefs = {"WantRunningSet": True, "WantRunning": True, "CorpDNSSet": True, "CorpDNS": False}
    if hostname:
        prefs.update(HostnameSet=True, Hostname=hostname)
    api("PATCH", "prefs", prefs)
    st = status() or {}
    if st.get("BackendState") == "Running":
        return None
    api("POST", "login-interactive")
    end = time.monotonic() + wait
    while time.monotonic() < end:
        st = status() or {}
        if st.get("AuthURL"):
            return st["AuthURL"]
        if st.get("BackendState") == "Running":
            return None
        time.sleep(0.25)
    raise Error("Tailscale did not return a sign-in link")


def serving(port):
    """True if Serve already publishes http://127.0.0.1:<port>."""
    try:
        cfg = api("GET", "serve-config", timeout=5)
    except (OSError, Error, ValueError):
        return False
    if not isinstance(cfg, dict):
        return False
    for site in (cfg.get("Web") or {}).values():
        for h in (site.get("Handlers") or {}).values():
            if (h.get("Proxy") or "").endswith(":%d" % port):
                return True
    return False


def serve(port):
    """Publish the host on https://<machine>.<tailnet>.ts.net — reachable only from the
    user's own tailnet. Returns (True, url) or (False, url-to-enable-HTTPS | message)."""
    st = status()
    if not st or st.get("BackendState") != "Running":
        return False, "not signed in"
    me = st.get("Self") or {}
    dns = (me.get("DNSName") or "").rstrip(".")
    if not dns:
        return False, "MagicDNS is off for this tailnet"
    if not _has_https(me):
        try:
            q = api("POST", "query-feature?feature=serve")
            if isinstance(q, dict) and q.get("URL"):
                return False, q["URL"]
        except (OSError, Error):
            pass
        return False, "https://login.tailscale.com/admin/dns"
    cfg = api("GET", "serve-config")
    if not isinstance(cfg, dict):
        cfg = {}
    cfg.setdefault("TCP", {})["443"] = {"HTTPS": True}
    cfg.setdefault("Web", {})["%s:443" % dns] = {"Handlers": {"/": {"Proxy": "http://127.0.0.1:%d" % port}}}
    api("POST", "serve-config", cfg)
    return True, "https://" + dns
