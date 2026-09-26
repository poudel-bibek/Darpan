#!/usr/bin/env python3
"""darpan-capture must exit promptly when its X server goes away (logout, crash): it used to hang in
exit() inside the CUDA/NVENC exit handlers. Starts a private Xvfb, waits for the helper's first
encoded frame, kills the X server and times the helper's exit. Needs Xvfb and an NVENC GPU.
Usage: python3 linux/tools/capture_exit_test.py [helper]"""
import os, struct, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
helper = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "native", "darpan-capture")
disp = next(":%d" % n for n in range(80, 120) if not os.path.exists("/tmp/.X11-unix/X%d" % n))
xvfb = subprocess.Popen(["Xvfb", disp, "-screen", "0", "640x360x24", "-nolisten", "tcp"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
cap = None
try:
    for _ in range(100):
        if os.path.exists("/tmp/.X11-unix/X" + disp[1:]):
            break
        time.sleep(0.05)
    cap = subprocess.Popen([helper, "--display", disp, "--fps", "30", "--bitrate", "2000", "--credits", "4"],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    first = threading.Event()

    def reader():
        while True:
            hdr = cap.stdout.read(24)
            if len(hdr) < 24:
                return
            n, flags = struct.unpack("<II", hdr[:8])
            cap.stdout.read(n)
            if not flags & 0x80000000:
                first.set()
    threading.Thread(target=reader, daemon=True).start()
    ok_first = first.wait(10)
    xvfb.terminate()
    xvfb.wait(5)
    t0 = time.monotonic()
    try:
        rc = cap.wait(5)
    except subprocess.TimeoutExpired:
        rc = None
    took = time.monotonic() - t0
    passed = ok_first and rc == 2 and took < 3
    print("  %s darpan-capture exits when X goes away   %s" % (
        "PASS" if passed else "FAIL",
        "first frame: %s, exit %s after %.1f s" % (ok_first, rc if rc is not None else "none (still running)", took)))
    print("\nRESULT:", "ALL PASS" if passed else "FAILURES")
    sys.exit(0 if passed else 1)
finally:
    if cap and cap.poll() is None:
        cap.kill()
        cap.wait()
    if xvfb.poll() is None:
        xvfb.kill()
