#!/usr/bin/env python3
"""Dev tool: read porthole-capture records from stdin, print stats, optionally dump raw H.264 and
decode selected frames to PNG (uses GStreamer avdec_h264) to verify the encoder output."""
import struct, sys, json, argparse

def read_records(f):
    hdr = struct.Struct("<IIQII")
    while True:
        h = f.read(hdr.size)
        if len(h) < hdr.size:
            return
        n, flags, ts, cap_us, enc_us = hdr.unpack(h)
        data = f.read(n)
        yield flags, ts, cap_us, enc_us, data

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--h264", help="write raw Annex-B stream here")
    ap.add_argument("--png", help="decode and write the LAST frame to this PNG")
    a = ap.parse_args()
    frames, total, keys, infos = [], 0, 0, []
    raw = open(a.h264, "wb") if a.h264 else None
    aus = []
    for flags, ts, cap_us, enc_us, data in read_records(sys.stdin.buffer):
        if flags & 0x80000000:
            infos.append(json.loads(data)); continue
        frames.append((flags, ts, cap_us, enc_us, len(data)))
        total += len(data); keys += flags & 1
        if raw: raw.write(data)
        aus.append(data)
    for i in infos: print("info:", i)
    if frames:
        n = len(frames)
        span = (frames[-1][1] - frames[0][1]) / 1e6 or 1e-9
        print(f"frames={n} keys={keys} span={span:.2f}s bytes={total} avg={total/n/1024:.1f}KB "
              f"first={frames[0][4]/1024:.1f}KB cap={sum(f[2] for f in frames)/n/1000:.2f}ms enc={sum(f[3] for f in frames)/n/1000:.2f}ms "
              f"refresh={sum(1 for f in frames if f[0]&2)}")
    if a.png and aus:
        import gi
        gi.require_version("Gst", "1.0")
        from gi.repository import Gst
        Gst.init(None)
        p = Gst.parse_launch("appsrc name=src format=time caps=video/x-h264,stream-format=byte-stream,alignment=au "
                             "! avdec_h264 ! videoconvert ! video/x-raw,format=RGB ! appsink name=sink sync=false")
        src, sink = p.get_by_name("src"), p.get_by_name("sink")
        p.set_state(Gst.State.PLAYING)
        for i, au in enumerate(aus):
            b = Gst.Buffer.new_wrapped(au); b.pts = i * 16_666_667
            src.emit("push-buffer", b)
        src.emit("end-of-stream")
        last = None
        while True:
            s = sink.emit("try-pull-sample", 3 * Gst.SECOND)
            if s is None: break
            last = s
        p.set_state(Gst.State.NULL)
        if last:
            caps = last.get_caps().get_structure(0)
            w, h = caps.get_value("width"), caps.get_value("height")
            ok, mi = last.get_buffer().map(Gst.MapFlags.READ)
            from PIL import Image
            Image.frombytes("RGB", (w, h), bytes(mi.data)).save(a.png)
            print("decoded last frame", w, h, "->", a.png)

if __name__ == "__main__":
    main()
