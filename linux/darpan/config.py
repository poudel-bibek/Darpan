"""Paths, settings and small file helpers."""
import json
import os
import socket
import tempfile

APP = "darpan"
VERSION = "1.2.0"
PROTO = 1

# Source tree (linux/) and installed tree (/opt/darpan) share the same layout:
#   <root>/darpan/  <root>/native/darpan-capture  <root>/web/  <root>/tailscale/
ROOT = os.environ.get("DARPAN_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(ROOT, "web")
CAPTURE_BIN = os.path.join(ROOT, "native", "darpan-capture")
TAILSCALE_DIR = os.path.join(ROOT, "tailscale")

DEFAULTS = {
    "port": 47470,
    "bind": "127.0.0.1",     # only reachable through Tailscale Serve (or on this machine)
    "fps": 60,
    "start_kbps": 12000,
    "max_kbps": 40000,
    "ping_every": 10,        # s between WebSocket pings to each viewer
    "silent_limit": 30,      # s without any frame from a viewer before its session is dropped
    "preset": 3,             # NVENC P3: best latency/size trade-off measured on this GPU
    "gpu": 0,
    "encoder": "auto",       # auto | nvenc | x264
    "max_sessions": 3,
}


def _xdg(var, default):
    v = os.environ.get(var)
    return v if v and os.path.isabs(v) else os.path.expanduser(default)


def config_dir():
    return os.path.join(_xdg("XDG_CONFIG_HOME", "~/.config"), APP)


def state_dir():
    return os.path.join(_xdg("XDG_STATE_HOME", "~/.local/state"), APP)


def data_dir():
    return os.path.join(_xdg("XDG_DATA_HOME", "~/.local/share"), APP)


def runtime_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp/%s-%d" % (APP, os.getuid())
    return os.path.join(base, APP)


def ensure_dirs():
    for d in (config_dir(), state_dir(), data_dir(), runtime_dir()):
        os.makedirs(d, mode=0o700, exist_ok=True)


def write_private(path, data):
    """Atomically write a file readable only by us."""
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def load():
    cfg = dict(DEFAULTS)
    try:
        with open(os.path.join(config_dir(), "config.json")) as f:
            user = json.load(f)
        cfg.update({k: v for k, v in user.items() if k in DEFAULTS})
    except FileNotFoundError:
        pass
    return cfg


def save(cfg):
    write_private(os.path.join(config_dir(), "config.json"), json.dumps(cfg, indent=2) + "\n")


def hostname():
    return socket.gethostname()
