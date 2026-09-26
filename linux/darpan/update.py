"""Darpan's update, from the Linux window: the newer version APT already knows about (the system
refreshes its lists daily, so this makes no network request), installed with one password."""
import os
import subprocess

HELPER = "/opt/darpan/update"


def available():
    """The newer version APT offers, or None."""
    env = dict(os.environ, LC_ALL="C")
    try:
        out = subprocess.run(["apt-cache", "policy", "darpan"], capture_output=True, text=True, env=env,
                             timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    got = dict(l.strip().split(": ", 1) for l in out.splitlines() if l.strip().startswith(("Installed: ", "Candidate: ")))
    have, new = got.get("Installed"), got.get("Candidate")
    if not have or not new or "(none)" in (have, new) or have == new:
        return None
    return new if subprocess.run(["dpkg", "--compare-versions", new, "gt", have]).returncode == 0 else None


def install():
    """Asks for the password (polkit). True once installed."""
    return subprocess.run(["pkexec", HELPER]).returncode == 0
