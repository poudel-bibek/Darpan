"""The computer's sound for viewers (PROTOCOL.md §12).

PipeWire's pw-record records the default output's monitor as a passive node: it never keeps the
sound card awake and delivers nothing while nothing plays, so silence costs no wake-ups. PCM is cut
into 10 ms frames, encoded with the system's libopus (CELT, restricted low delay) and handed to every
listening viewer. It runs only while at least one viewer listens."""

import ctypes
import ctypes.util
import logging
import os
import shutil
import struct
import subprocess
import time

log = logging.getLogger(__name__)

RATE, CHANNELS, FRAME = 48000, 2, 480              # 10 ms at 48 kHz
FRAME_BYTES = FRAME * CHANNELS * 2                  # s16 interleaved
SILENT = bytes(FRAME_BYTES)
KBPS = 128
HDR = struct.Struct(">BBIQ")                        # kind 0x03, flags, seq (10 ms slots), capture µs
FIRST = 0x01                                        # first packet after silence or a gap
GAP = 0.05                                          # s without PCM: the stream paused (nothing played)

_APPLICATION_RESTRICTED_LOWDELAY = 2051
_SET_BITRATE, _SET_COMPLEXITY, _GET_LOOKAHEAD = 4002, 4010, 4027


def _libopus():
    name = ctypes.util.find_library("opus")
    return ctypes.CDLL(name) if name else None


def available():
    """Sound needs pw-record (PipeWire) and libopus."""
    return shutil.which("pw-record") is not None and ctypes.util.find_library("opus") is not None


class Opus:
    def __init__(self):
        lib = self.lib = _libopus()
        lib.opus_encoder_create.restype = ctypes.c_void_p
        lib.opus_encoder_create.argtypes = [ctypes.c_int32, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        lib.opus_encode.restype = ctypes.c_int32
        lib.opus_encode.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int32]
        lib.opus_encoder_destroy.argtypes = [ctypes.c_void_p]
        err = ctypes.c_int()
        self.enc = lib.opus_encoder_create(RATE, CHANNELS, _APPLICATION_RESTRICTED_LOWDELAY, ctypes.byref(err))
        if not self.enc or err.value:
            raise OSError("opus_encoder_create failed (%d)" % err.value)
        enc = ctypes.c_void_p(self.enc)
        lib.opus_encoder_ctl(enc, _SET_BITRATE, ctypes.c_int32(KBPS * 1000))
        lib.opus_encoder_ctl(enc, _SET_COMPLEXITY, ctypes.c_int32(5))
        lookahead = ctypes.c_int32()
        lib.opus_encoder_ctl(enc, _GET_LOOKAHEAD, ctypes.byref(lookahead))
        self.lookahead = lookahead.value
        self.out = ctypes.create_string_buffer(1500)

    def encode(self, pcm):
        n = self.lib.opus_encode(self.enc, pcm, FRAME, self.out, len(self.out))
        if n < 0:
            raise OSError("opus_encode failed (%d)" % n)
        return self.out.raw[:n]

    def close(self):
        if self.enc:
            self.lib.opus_encoder_destroy(self.enc)
            self.enc = None


def lookahead():
    """Encoder delay in samples at 48 kHz, for the client's latency figure (Opus pre-skip)."""
    enc = Opus()
    try:
        return enc.lookahead
    finally:
        enc.close()


class Capture:
    """pw-record → 10 ms frames → Opus packets → on_packet(bytes). stop() ends pw-record; if it ends on
    its own (PipeWire restarted), on_exit(seconds it ran) is called."""

    def __init__(self, loop, on_packet, on_exit):
        self.loop, self.on_packet, self.on_exit = loop, on_packet, on_exit
        self.started = 0.0
        self.proc = self.opus = None
        self.buf = bytearray()
        self.header = True                             # a WAV header precedes the PCM
        self.seq = 0
        self.gap = True
        self.last = 0.0

    def start(self):
        self.opus = Opus()
        self.proc = subprocess.Popen(
            ["pw-record", "--rate", str(RATE), "--channels", str(CHANNELS), "--format", "s16",
             "--latency", "10ms", "-P",
             "{ stream.capture.sink = true, node.passive = true, node.name = darpan-sound, "
             "node.description = \"Darpan (sound for viewers)\" }", "-"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        fd = self.proc.stdout.fileno()
        os.set_blocking(fd, False)
        self.loop.add_reader(fd, self._readable)
        self.started = time.monotonic()
        log.info("sound: capturing (pw-record %d)", self.proc.pid)

    def stop(self):
        proc, self.proc = self.proc, None
        if proc:
            self.loop.remove_reader(proc.stdout.fileno())
            proc.terminate()
            try:
                proc.wait(2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            proc.stdout.close()
            log.info("sound: stopped")
        if self.opus:
            self.opus.close()
            self.opus = None

    def _readable(self):
        try:
            chunk = os.read(self.proc.stdout.fileno(), 65536)
        except BlockingIOError:
            return
        if not chunk:                                  # pw-record ended (PipeWire restarted?)
            log.warning("sound: pw-record exited")
            self.stop()
            self.on_exit(time.monotonic() - self.started)
            return
        now = time.monotonic()
        if now - self.last > GAP:
            self.gap = True
        self.last = now
        self.buf += chunk
        if self.header:                                # RIFF … "data" <size>: PCM follows
            i = self.buf.find(b"data")
            if i < 0 or len(self.buf) < i + 8:
                return
            del self.buf[:i + 8]
            self.header = False
        while len(self.buf) >= FRAME_BYTES:
            pcm = bytes(self.buf[:FRAME_BYTES])
            del self.buf[:FRAME_BYTES]
            self.seq = (self.seq + 1) & 0xFFFFFFFF
            if pcm == SILENT:                          # digital silence isn't sent
                self.gap = True
                continue
            captured = now - len(self.buf) / FRAME_BYTES * FRAME / RATE   # later frames are still queued
            self.on_packet(HDR.pack(3, FIRST if self.gap else 0, self.seq, int(captured * 1e6)) + self.opus.encode(pcm))
            self.gap = False
