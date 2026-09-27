#!/usr/bin/env bash
# Fails if tracked or new (untracked, not ignored) files, or with --history commit metadata, contain
# personal data. New files count so a board message or source file is caught before it is committed.
# Generic patterns: e-mail addresses, IPv4 addresses, home-directory paths, tailnet host names.
# Personal terms (names, accounts, machine names…) go in .private-denylist (untracked, one
# case-insensitive fixed string per line, # comments) so the list itself is never committed.
# The repository's own addresses, on GitHub and its Pages site, may name the account (the owner agreed).
# The check itself is Python 3, so it behaves the same with GNU tools (Linux) and BSD ones (macOS).
cd "$(git rev-parse --show-toplevel)" || exit 2
exec python3 - "$@" <<'PY'
import os
import re
import subprocess
import sys


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, check=True).stdout


names = git("ls-files", "-z") + git("ls-files", "-z", "--others", "--exclude-standard")
skip = re.compile(rb"^linux/native/third_party/|\.(png|jpg|ico|icns|a|so)$")
files = [n for n in dict.fromkeys(names.split(b"\0")) if n and not skip.search(n)]

PATTERNS = [   # (label, pattern, allowed matches)
    ("email", rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
     rb"@(darpan\.invalid|example\.(com|org)|users\.noreply\.github\.com)$"),   # placeholders, GitHub no-reply
    ("ip", rb"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])",
     rb"^(127\.0\.0\.1|0\.0\.0\.0|100\.64\.0\.0|192\.0\.2\.\d+|198\.51\.100\.\d+|203\.0\.113\.\d+)$"),  # loopback, any, CGNAT constant, documentation
    ("path", rb"/(?:home|Users)/[A-Za-z][A-Za-z0-9._-]+", None),
    ("tailnet", rb"[A-Za-z0-9-]+\.tail[0-9a-f]{4,}\.ts\.net", None),
]
PATTERNS = [(label, re.compile(p), re.compile(ok) if ok else None) for label, p, ok in PATTERNS]

deny = []
if os.path.exists(".private-denylist"):
    with open(".private-denylist", encoding="utf-8") as f:
        deny = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
else:
    print("note: no .private-denylist — only generic patterns were checked", file=sys.stderr)
# str, not bytes: re.I on bytes folds ASCII only, and names can have accents or other scripts
denied = re.compile("|".join(re.escape(d) for d in deny), re.I) if deny else None
# github.com/<owner>/<repo>, its API address and <owner>.github.io/<repo>, from origin; nothing else is let through
origin = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
m = re.search(r"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", origin)
own = None
if m:
    own = re.compile(r"(?:github\.com/{0}/{1}|api\.github\.com/repos/{0}/{1}|{0}\.github\.io/{1})(?![\w.-])"
                     .format(re.escape(m[1]), re.escape(m[2])), re.I)


def personal(text):
    return denied.search(own.sub("", text) if own else text)


found = False


def report(label, text):
    global found
    found = True
    print("%-10s %s" % (label, text))


for name in files:
    try:
        with open(name, "rb") as f:
            data = f.read()
    except (FileNotFoundError, IsADirectoryError):      # deleted in the working tree, or a submodule
        continue
    if b"\0" in data[:8000]:                              # binary, like grep -I
        continue
    shown = name.decode("utf-8", "replace")
    for n, line in enumerate(data.split(b"\n"), 1):
        for label, rx, ok in PATTERNS:
            for m in rx.findall(line):
                if not (ok and ok.search(m)):
                    report(label, "%s:%d:%s" % (shown, n, m.decode("utf-8", "replace")))
        if denied:
            text = line.decode("utf-8", "replace")
            if personal(text):
                report("denylist", "%s:%d:%s" % (shown, n, text.strip()))

if "--history" in sys.argv[1:]:
    for line in git("log", "--all", "--format=%h %an <%ae> %s").decode("utf-8", "replace").splitlines():
        if not re.search(r"<[^>]*@users\.noreply\.github\.com>", line):
            report("commit", line)
    if denied:
        for rec in git("log", "--all", "--format=%h %B%x01").split(b"\x01"):
            for line in rec.strip().decode("utf-8", "replace").split("\n"):
                if personal(line):
                    report("commit", line)

if not found:
    print("clean: no personal data found")
sys.exit(1 if found else 0)
PY
