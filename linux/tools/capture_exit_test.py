#!/usr/bin/env python3
"""darpan-capture must exit promptly when its X server goes away (logout, crash): it used to hang in
exit() inside the CUDA/NVENC exit handlers. Starts a private Xvfb, waits for the helper's first
encoded frame, kills the X server and times the helper's exit. Then the same without shared memory,
as with the login screen's X server, which runs as another user, and once through CUDA instead of Vulkan
Video (the fallback). The first frame must also show the screen's colour, except in the plain case.
Needs Xvfb, xsetroot and an NVENC GPU.
Usage: python3 linux/tools/capture_exit_test.py [helper]"""
import os, struct, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from test_host import decode_frames  # noqa: E402
helper = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "native", "darpan-capture")


def run(xargs, env=None):
    disp = next(":%d" % n for n in range(80, 120) if not os.path.exists("/tmp/.X11-unix/X%d" % n))
    xvfb = subprocess.Popen(["Xvfb", disp, "-screen", "0", "640x360x24", "-nolisten", "tcp", "-noreset"] + xargs,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cap = None
    try:
        for _ in range(100):
            if os.path.exists("/tmp/.X11-unix/X" + disp[1:]):
                break
            time.sleep(0.05)
        subprocess.run(["xsetroot", "-display", disp, "-solid", "#ff8000"], check=True)
        cap = subprocess.Popen([helper, "--display", disp, "--fps", "30", "--bitrate", "2000", "--credits", "4"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=dict(os.environ, **(env or {})))
        first = threading.Event()
        err, au, info = [], [], []

        def reader():
            while True:
                hdr = cap.stdout.read(24)
                if len(hdr) < 24:
                    return
                n, flags = struct.unpack("<II", hdr[:8])
                data = cap.stdout.read(n)
                if flags & 0x80000000:
                    info.append(data.decode(errors="replace"))
                else:
                    au.append(data)
                    first.set()
        threading.Thread(target=reader, daemon=True).start()
        threading.Thread(target=lambda: err.append(cap.stderr.read().decode(errors="replace")), daemon=True).start()
        ok_first = first.wait(10)
        mib = None                  # the helper's GPU memory while it streams
        q = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True)
        for line in q.stdout.splitlines():
            pid, _, used = line.partition(",")
            if pid.strip() == str(cap.pid):
                mib = int(used)
        xvfb.terminate()
        xvfb.wait(5)
        t0 = time.monotonic()
        try:
            rc = cap.wait(5)
        except subprocess.TimeoutExpired:
            rc = None
        took = time.monotonic() - t0
        time.sleep(0.1)
        return ok_first, rc, took, "".join(err), au[:1], info, mib
    finally:
        if cap and cap.poll() is None:
            cap.kill()
            cap.wait()
        if xvfb.poll() is None:
            xvfb.kill()


results = []
for name, xargs, env, api in (("", [], None, "vulkan"),
                              (" (no shared memory)", ["-extension", "MIT-SHM"], None, "vulkan"),
                              (" (CUDA)", [], {"DARPAN_NVENC_CUDA": "1"}, "cuda")):
    ok_first, rc, took, err, au, info, mib = run(xargs, env)
    passed = ok_first and rc == 2 and took < 3 and any('"api":"%s"' % api in i for i in info)
    passed = passed and (api != "vulkan" or (mib is not None and mib < 64))   # the point: no CUDA context
    px = None
    if (xargs or env) and passed:
        with tempfile.TemporaryDirectory() as tmp:
            px = decode_frames(au, os.path.join(tmp, "frame.png")).getpixel((320, 180))
        passed = (not xargs or "copying frames" in err) and abs(px[0] - 255) < 12 and abs(px[1] - 128) < 12 and px[2] < 12
    results.append(passed)
    print("  %s darpan-capture exits when X goes away%s   %s" % (
        "PASS" if passed else "FAIL", name,
        "first frame: %s, exit %s after %.1f s, GPU memory %s MiB%s" % (
            ok_first, rc if rc is not None else "none (still running)", took, mib, ", colour %s" % (px,) if px else "")))
print("\nRESULT:", "ALL PASS" if all(results) else "FAILURES")
sys.exit(0 if all(results) else 1)
