#!/usr/bin/env python3
"""The APT index works the way installed hosts use it: a tiny package is indexed by
packaging/apt-index.sh, served as the Pages site serves it (<site>/apt/<file>, see
scripts/publish-updates.sh), and an unprivileged apt with private state fetches, verifies and downloads it. An index signed with
another key must be refused. Needs apt-get, apt-ftparchive, dpkg-deb and gpg; touches nothing global.
Usage: python3 linux/tools/apt_test.py"""
import http.server, os, subprocess, sys, tempfile, threading, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failed = False


def ok(name, cond, detail=""):
    global failed
    failed |= not cond
    print("  %s %-44s %s" % ("PASS" if cond else "FAIL", name, detail))


def run(*cmd, env=None, cwd=None):
    return subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=cwd)


def key(home, uid):
    os.makedirs(home, mode=0o700)
    env = dict(os.environ, GNUPGHOME=home)
    run("gpg", "--batch", "--passphrase", "", "--quick-generate-key", uid, "ed25519", "sign", "never", env=env)
    return env


def main():
    t = tempfile.mkdtemp(prefix="darpan-apt-")
    pkg = os.path.join(t, "pkg")
    os.makedirs(os.path.join(pkg, "DEBIAN"))
    with open(os.path.join(pkg, "DEBIAN", "control"), "w") as f:
        f.write("Package: darpan-apt-test\nVersion: 9.9.9\nArchitecture: all\nMaintainer: nobody <nobody@example.com>\n"
                "Description: test\n")
    deb = os.path.join(t, "test.deb")
    run("dpkg-deb", "--root-owner-group", "--build", pkg, deb)
    good, other = key(os.path.join(t, "good"), "Darpan test"), key(os.path.join(t, "other"), "Someone else")
    keyring = os.path.join(t, "keyring.gpg")
    with open(keyring, "wb") as f:
        f.write(subprocess.run(["gpg", "--export"], capture_output=True, env=good).stdout)
    objects = os.path.join(t, "objects")
    index = os.path.join(ROOT, "packaging", "apt-index.sh")

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            u = urllib.parse.urlsplit(self.path)
            p = os.path.join(objects, os.path.basename(u.path))
            if u.path.startswith("/Darpan/apt/") and os.path.isfile(p):
                data = open(p, "rb").read()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(404)
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    parts = os.path.join(t, "parts")
    os.makedirs(parts)
    with open(os.path.join(parts, "darpan.sources"), "w") as f:
        f.write("Types: deb\nURIs: http://127.0.0.1:%d/Darpan/apt/\nSuites: ./\nSigned-By: %s\n"
                % (srv.server_address[1], keyring))

    def apt(*args):
        state = os.path.join(t, "state")
        for d in ("state/lists/partial", "cache/archives/partial"):
            os.makedirs(os.path.join(t, d), exist_ok=True)
        opts = ["-o", "Dir::Etc::SourceList=/dev/null", "-o", "Dir::Etc::SourceParts=" + parts, "-o", "Dir::State=" + state,
                "-o", "Dir::State::Lists=" + os.path.join(state, "lists"), "-o", "Dir::Cache=" + os.path.join(t, "cache"),
                "-o", "Dir::State::status=/dev/null", "-o", "Debug::NoLocking=1", "-o", "APT::Sandbox::User=" + os.environ.get("USER", "nobody")]
        return run(args[0], *opts, *args[1:], cwd=t)

    print("apt index (packaging/apt-index.sh)")
    r = run(index, deb, objects, env=good)
    ok("index written", r.returncode == 0 and all(os.path.exists(os.path.join(objects, n)) for n in ("darpan_amd64.deb", "Packages", "InRelease")), r.stderr.strip()[-80:])
    listed = [l.split()[-1] for l in open(os.path.join(objects, "InRelease")) if l.startswith(" ") and len(l.split()) == 3]
    ok("index lists Packages only", set(listed) == {"Packages"}, str(sorted(set(listed))))
    r = apt("apt-get", "update")
    ok("apt update from the site", r.returncode == 0 and "InRelease" in r.stdout, (r.stderr or r.stdout).strip()[-80:])
    r = apt("apt-cache", "policy", "darpan-apt-test")
    ok("candidate from the index", "Candidate: 9.9.9" in r.stdout, r.stdout.split("\n")[2].strip() if r.stdout.count("\n") > 2 else r.stderr.strip()[-60:])
    r = apt("apt-get", "download", "darpan-apt-test")
    ok("package downloads", r.returncode == 0 and os.path.exists(os.path.join(t, "darpan-apt-test_9.9.9_all.deb")), r.stderr.strip()[-80:])
    run(index, deb, objects, env=other)
    for d in ("state", "cache"):
        subprocess.run(["rm", "-rf", os.path.join(t, d)])
    r = apt("apt-get", "update")
    ok("index signed by another key refused", "is not signed" in r.stderr or "NO_PUBKEY" in r.stderr, r.stderr.strip()[-60:])
    r = apt("apt-cache", "policy", "darpan-apt-test")
    ok("no candidate from a bad index", "Candidate: 9.9.9" not in r.stdout)
    srv.shutdown()
    subprocess.run(["rm", "-rf", t])
    print("\nRESULT:", "FAILED" if failed else "ALL PASS")
    sys.exit(1 if failed else 0)


main()
