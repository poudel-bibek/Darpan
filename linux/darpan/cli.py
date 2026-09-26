"""darpan command line."""
import argparse
import asyncio
import getpass
import logging
import os
import shutil
import signal
import subprocess
import sys
import time

from . import auth, config, control, tailscale

log = logging.getLogger("darpan")


def _serve(args):
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname).1s %(name)s: %(message)s", stream=sys.stderr)
    from .session import Hub
    from .web import Server
    config.ensure_dirs()
    cfg = config.load()
    if args.port:
        cfg["port"] = args.port
    hub = Hub(cfg)
    if not hub.auth.configured:
        hub.auth.generate()
        log.info("generated an access password — run `darpan status` to see it")

    async def main():
        await hub.start()
        server = Server(hub, cfg)
        await server.start()
        ctl = await control.serve(hub)
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            loop.add_signal_handler(sig, stop.set)
        await stop.wait()
        log.info("shutting down")
        hub.kick(code=4004, reason="host shutting down")
        await asyncio.sleep(0.3)
        for s in list(hub.sessions):
            await s._close()
        await hub.session_ended()
        ctl.close()
        await server.close()

    asyncio.run(main())


def _status(args):
    store = auth.AuthStore()
    print("Darpan %s on %s" % (config.VERSION, config.hostname()))
    try:
        st = control.request("status")
        enc = ("NVENC on " + st["encoder"]) if st.get("encoder") else "x264 (software)"
        if st.get("restart_for_gpu"):
            enc = "x264 (software): the NVIDIA driver was updated, restart to use the GPU"
        print("  Host service : running on port %d, encoder %s" % (st["port"], enc))
    except OSError:
        st = None
        print("  Host service : NOT running  (start it: systemctl --user start darpan)")
    ts = tailscale.summary()
    state = ts.get("state")
    if state == "Running":
        print("  Network      : Tailscale connected%s" % (" as " + ts["user"] if ts.get("user") else ""))
        if tailscale.serving(st["port"] if st else config.load()["port"]):
            print("  Address      : %s" % (ts.get("url") or "?"))
        else:
            print("  Address      : not published yet — run `darpan setup` (or click Publish in the app)")
    elif state == "stopped":
        print("  Network      : Tailscale not running  (systemctl --user start darpan-net)")
    else:
        print("  Network      : Tailscale %s  (run: darpan setup)" % state)
    pw = store.visible_password()
    if pw:
        print("  Password     : %s   (change with: darpan password --set)" % pw)
    else:
        print("  Password     : %s" % ("set by you (hidden)" if store.configured else "NOT SET — run: darpan password --set"))
    if st:
        ss = st.get("sessions") or []
        print("  Sessions     : %d" % len(ss))
        for s in ss:
            print("    • %s from %s since %s%s" % (s["client"], s["source"], time.strftime("%H:%M", time.localtime(s["since"])),
                                              " — streaming %dx%d" % (s["w"], s["h"]) if s["streaming"] else ""))


def _password(args):
    store = auth.AuthStore()
    if args.generate:
        pw = store.generate()
        print("New password: %s" % pw)
    elif args.set:
        while True:
            a = getpass.getpass("New password (min 8 chars): ")
            if len(a) < 8:
                print("Too short.")
                continue
            if getpass.getpass("Repeat: ") != a:
                print("Didn't match.")
                continue
            store.set_password(a)
            break
        print("Password changed.")
    else:
        pw = store.visible_password()
        print(pw if pw else ("(a custom password is set; use --set to change it)" if store.configured else "(no password set)"))
        return
    try:
        control.request("reload")
    except OSError:
        pass


def _open_url(url):
    if shutil.which("xdg-open"):
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _setup(args):
    store = auth.AuthStore()
    print("Darpan setup\n")
    if not store.configured:
        store.generate()
    pw = store.visible_password()
    print("1. Access password: %s" % (pw or "(your own password)"))
    print("   (change any time with: darpan password --set)\n")

    print("2. Private network (Tailscale)")
    ts = tailscale.summary()
    if ts["state"] == "stopped":
        subprocess.run(["systemctl", "--user", "start", "darpan-net.service"], check=False)
        for _ in range(20):
            time.sleep(0.5)
            ts = tailscale.summary()
            if ts["state"] != "stopped":
                break
    if ts["state"] == "stopped":
        print("   tailscaled isn't running. Check: journalctl --user -u darpan-net")
        return 1
    if ts["state"] != "Running":
        url = tailscale.login(config.hostname().lower())
        if url:
            print("   Sign in (a browser window should open):\n\n      %s\n" % url)
            _open_url(url)
        print("   Waiting for sign-in", end="", flush=True)
        while True:
            time.sleep(2)
            ts = tailscale.summary()
            if ts["state"] == "Running":
                break
            print(".", end="", flush=True)
        print(" done.")
    print("   Connected%s.\n" % (" as " + ts["user"] if ts.get("user") else ""))

    print("3. Publishing the remote desktop on your tailnet (HTTPS)")
    cfg = config.load()
    while True:
        ok, msg = tailscale.serve(control.host_port(cfg["port"]))
        if ok:
            break
        if msg.startswith("https://"):
            print("   Tailscale needs HTTPS enabled for your tailnet (one click):\n\n      %s\n" % msg)
            _open_url(msg)
            input("   Press Enter after enabling it... ")
            continue
        print("   tailscale serve failed: %s" % msg)
        return 1
    ts = tailscale.summary()
    print("   Done.\n")
    print("On your Mac:")
    print("  • Install Tailscale (App Store or tailscale.com/download) and sign in with the same account.")
    print("  • Open  %s  and enter the password above." % (ts.get("url") or "https://<this machine>.ts.net"))
    print("\nImportant for unattended use: in https://login.tailscale.com/admin/machines open this")
    print("machine's menu and choose \"Disable key expiry\", otherwise it drops off after 180 days.")
    return 0


def _doctor(args):
    ok = True

    def check(name, good, detail=""):
        nonlocal ok
        ok &= bool(good)
        print("  %s %-22s %s" % ("✓" if good else "✗", name, detail))

    print("Darpan diagnostics")
    disp = os.environ.get("DISPLAY")
    check("X display", bool(disp), disp or "DISPLAY not set (is a desktop session running?)")
    try:
        from .x11 import X11
        x = X11(disp)
        check("X11 input (XTest)", True, "screen %dx%d" % x.size)
        x.close()
    except Exception as e:
        check("X11 input (XTest)", False, str(e))
    check("capture helper", os.access(config.CAPTURE_BIN, os.X_OK), config.CAPTURE_BIN)
    from . import capture
    gpu = asyncio.run(capture.probe_nvenc())
    check("NVENC", True if gpu else True, gpu or "unavailable — software x264 fallback will be used")
    if capture.driver_restart_needed():
        check("NVIDIA driver", False, "updated but not loaded yet: restart this computer to use the GPU")
    r = subprocess.run(["gst-inspect-1.0", "x264enc"], capture_output=True)
    check("x264 fallback", r.returncode == 0, "gstreamer1.0-plugins-ugly" if r.returncode else "ok")
    check("xclip", bool(shutil.which("xclip")))
    check("xrandr", bool(shutil.which("xrandr")))
    check("password", auth.AuthStore().configured)
    try:
        st = control.request("status")
        check("host service", True, "port %d" % st["port"])
    except OSError:
        check("host service", False, "not running — systemctl --user status darpan")
    ts = tailscale.summary()
    check("tailscale", ts["state"] == "Running", ts["state"] + (" " + ts["url"] if ts.get("url") else ""))
    for p in ts.get("peers", []):
        if p.get("online"):
            print("      peer %-40s %s" % (p["name"], "direct" if p["direct"] else "relayed via %s" % p.get("relay")))
    return 0 if ok else 1


def _disconnect(args):
    try:
        r = control.request("kick", sid=args.sid)
        print("Disconnected %d session(s)." % r.get("kicked", 0))
    except OSError:
        print("Host service is not running.")


def _net(args):
    ts = tailscale.summary()
    print("state   :", ts["state"])
    for k in ("user", "tailnet", "url"):
        if ts.get(k):
            print("%-8s: %s" % (k, ts[k]))
    for p in ts.get("peers", []):
        print("peer    : %-40s %s%s" % (p["name"], "online " if p["online"] else "offline",
                                       ("direct" if p["direct"] else "relay " + str(p.get("relay"))) if p["online"] else ""))


def _gui(args):
    from . import gui
    return gui.main()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="darpan", description="Darpan — fast, private remote desktop host")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("serve", help="run the host (normally started automatically)")
    p.add_argument("--port", type=int)
    p.add_argument("-v", "--verbose", action="store_true")
    sub.add_parser("status", help="show address, password and sessions")
    p = sub.add_parser("password", help="show or change the access password")
    p.add_argument("--set", action="store_true", help="choose your own password")
    p.add_argument("--generate", action="store_true", help="generate a new random password")
    sub.add_parser("setup", help="first-time setup: password + Tailscale sign-in")
    sub.add_parser("doctor", help="check that everything works")
    p = sub.add_parser("disconnect", help="disconnect remote sessions")
    p.add_argument("sid", nargs="?", help="session id (default: all)")
    sub.add_parser("net", help="show private network (Tailscale) status and peers")
    sub.add_parser("gui", help="open the status window")
    sub.add_parser("version")
    args = ap.parse_args(argv)
    fn = {"serve": _serve, "status": _status, "password": _password, "setup": _setup, "doctor": _doctor,
          "disconnect": _disconnect, "net": _net, "gui": _gui,
          "version": lambda a: print(config.VERSION)}.get(args.cmd)
    if not fn:
        if os.environ.get("DISPLAY") and sys.stdin.isatty() is False:
            return _gui(args)
        ap.print_help()
        return 0
    return fn(args) or 0
