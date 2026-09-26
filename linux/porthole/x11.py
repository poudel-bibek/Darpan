"""Minimal ctypes bindings to Xlib / XTest / XFixes — only what the host needs.

One Display connection lives on the asyncio thread: input is injected with XTest and
flushed immediately, and X events (cursor shape changes, clipboard owner changes, screen
resizes) are read from the same connection through loop.add_reader — no extra threads,
no polling.
"""
import ctypes
import logging
import os
import zlib
import struct

log = logging.getLogger("porthole.x11")

_x11 = ctypes.CDLL("libX11.so.6")
_xtst = ctypes.CDLL("libXtst.so.6")
_xfixes = ctypes.CDLL("libXfixes.so.3")

_DP = ctypes.c_void_p
_Window = ctypes.c_ulong
_Atom = ctypes.c_ulong
_KeySym = ctypes.c_ulong
_int_p = ctypes.POINTER(ctypes.c_int)


def _sig(lib, name, restype, *argtypes):
    f = getattr(lib, name)
    f.restype = restype
    f.argtypes = list(argtypes)
    return f


XOpenDisplay = _sig(_x11, "XOpenDisplay", _DP, ctypes.c_char_p)
XCloseDisplay = _sig(_x11, "XCloseDisplay", ctypes.c_int, _DP)
XDefaultRootWindow = _sig(_x11, "XDefaultRootWindow", _Window, _DP)
XConnectionNumber = _sig(_x11, "XConnectionNumber", ctypes.c_int, _DP)
XPending = _sig(_x11, "XPending", ctypes.c_int, _DP)
XNextEvent = _sig(_x11, "XNextEvent", ctypes.c_int, _DP, ctypes.c_void_p)
XFlush = _sig(_x11, "XFlush", ctypes.c_int, _DP)
XSync = _sig(_x11, "XSync", ctypes.c_int, _DP, ctypes.c_int)
XFree = _sig(_x11, "XFree", ctypes.c_int, ctypes.c_void_p)
XInternAtom = _sig(_x11, "XInternAtom", _Atom, _DP, ctypes.c_char_p, ctypes.c_int)
XSelectInput = _sig(_x11, "XSelectInput", ctypes.c_int, _DP, _Window, ctypes.c_long)
XGetGeometry = _sig(_x11, "XGetGeometry", ctypes.c_int, _DP, _Window, ctypes.POINTER(_Window),
                    _int_p, _int_p, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
                    ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint))
XKeysymToKeycode = _sig(_x11, "XKeysymToKeycode", ctypes.c_ubyte, _DP, _KeySym)
XKeycodeToKeysym = _sig(_x11, "XKeycodeToKeysym", _KeySym, _DP, ctypes.c_ubyte, ctypes.c_int)
XDisplayKeycodes = _sig(_x11, "XDisplayKeycodes", ctypes.c_int, _DP, _int_p, _int_p)
XGetKeyboardMapping = _sig(_x11, "XGetKeyboardMapping", ctypes.POINTER(_KeySym), _DP, ctypes.c_ubyte,
                           ctypes.c_int, _int_p)
XChangeKeyboardMapping = _sig(_x11, "XChangeKeyboardMapping", ctypes.c_int, _DP, ctypes.c_int,
                              ctypes.c_int, ctypes.POINTER(_KeySym), ctypes.c_int)
XAutoRepeatOn = _sig(_x11, "XAutoRepeatOn", ctypes.c_int, _DP)
XAutoRepeatOff = _sig(_x11, "XAutoRepeatOff", ctypes.c_int, _DP)

XTestQueryExtension = _sig(_xtst, "XTestQueryExtension", ctypes.c_int, _DP, _int_p, _int_p, _int_p, _int_p)
XTestFakeMotionEvent = _sig(_xtst, "XTestFakeMotionEvent", ctypes.c_int, _DP, ctypes.c_int, ctypes.c_int,
                            ctypes.c_int, ctypes.c_ulong)
XTestFakeButtonEvent = _sig(_xtst, "XTestFakeButtonEvent", ctypes.c_int, _DP, ctypes.c_uint, ctypes.c_int,
                            ctypes.c_ulong)
XTestFakeKeyEvent = _sig(_xtst, "XTestFakeKeyEvent", ctypes.c_int, _DP, ctypes.c_uint, ctypes.c_int,
                         ctypes.c_ulong)

XFixesQueryExtension = _sig(_xfixes, "XFixesQueryExtension", ctypes.c_int, _DP, _int_p, _int_p)
XFixesSelectCursorInput = _sig(_xfixes, "XFixesSelectCursorInput", None, _DP, _Window, ctypes.c_ulong)
XFixesSelectSelectionInput = _sig(_xfixes, "XFixesSelectSelectionInput", None, _DP, _Window, _Atom,
                                  ctypes.c_ulong)


class _XKeyboardState(ctypes.Structure):
    _fields_ = [("key_click_percent", ctypes.c_int), ("bell_percent", ctypes.c_int),
                ("bell_pitch", ctypes.c_uint), ("bell_duration", ctypes.c_uint),
                ("led_mask", ctypes.c_ulong), ("global_auto_repeat", ctypes.c_int),
                ("auto_repeats", ctypes.c_char * 32)]


XGetKeyboardControl = _sig(_x11, "XGetKeyboardControl", ctypes.c_int, _DP, ctypes.POINTER(_XKeyboardState))


class _XFixesCursorImage(ctypes.Structure):
    _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short),
                ("width", ctypes.c_ushort), ("height", ctypes.c_ushort),
                ("xhot", ctypes.c_ushort), ("yhot", ctypes.c_ushort),
                ("cursor_serial", ctypes.c_ulong), ("pixels", ctypes.POINTER(ctypes.c_ulong)),
                ("atom", _Atom), ("name", ctypes.c_char_p)]


XFixesGetCursorImage = _sig(_xfixes, "XFixesGetCursorImage", ctypes.POINTER(_XFixesCursorImage), _DP)


class _XAnyEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", _DP), ("window", _Window)]


class _XConfigureEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", _DP), ("event", _Window), ("window", _Window),
                ("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
                ("border_width", ctypes.c_int), ("above", _Window), ("override_redirect", ctypes.c_int)]


class _XFixesSelectionNotifyEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", _DP), ("window", _Window), ("subtype", ctypes.c_int),
                ("owner", _Window), ("selection", _Atom), ("timestamp", ctypes.c_ulong),
                ("selection_timestamp", ctypes.c_ulong)]


_XEvent = ctypes.c_long * 24          # sizeof(XEvent) == 192 on LP64

_ErrorHandler = ctypes.CFUNCTYPE(ctypes.c_int, _DP, ctypes.c_void_p)
XSetErrorHandler = _sig(_x11, "XSetErrorHandler", ctypes.c_void_p, _ErrorHandler)


@_ErrorHandler
def _on_x_error(dpy, ev):  # never abort the daemon because of an X protocol error
    return 0


XSetErrorHandler(_on_x_error)

ConfigureNotify = 22
StructureNotifyMask = 1 << 17
XFixesDisplayCursorNotifyMask = 1
XFixesSetSelectionOwnerNotifyMask = 1

# DOM MouseEvent.button -> X button
BUTTONS = {0: 1, 1: 2, 2: 3, 3: 8, 4: 9}


def png_rgba(w, h, rgba):
    """Tiny PNG encoder (RGBA8, filter 0). Enough for cursor images."""
    stride = w * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


class X11:
    """Input injection + change notifications for one X display."""

    def __init__(self, display_name=None):
        name = display_name or os.environ.get("DISPLAY")
        self.dpy = XOpenDisplay(name.encode() if name else None)
        if not self.dpy:
            raise RuntimeError("cannot open X display %r" % name)
        self.name = name
        self.root = XDefaultRootWindow(self.dpy)
        a = ctypes.c_int()
        b = ctypes.c_int()
        c = ctypes.c_int()
        d = ctypes.c_int()
        if not XTestQueryExtension(self.dpy, ctypes.byref(a), ctypes.byref(b), ctypes.byref(c), ctypes.byref(d)):
            raise RuntimeError("X server lacks the XTEST extension")
        self.fixes_event = -1
        if XFixesQueryExtension(self.dpy, ctypes.byref(a), ctypes.byref(b)):
            self.fixes_event = a.value
        self.clipboard_atom = XInternAtom(self.dpy, b"CLIPBOARD", 0)
        mn, mx = ctypes.c_int(), ctypes.c_int()
        XDisplayKeycodes(self.dpy, ctypes.byref(mn), ctypes.byref(mx))
        self.min_kc, self.max_kc = mn.value, mx.value
        self._spare = self._find_spare_keycodes()
        self._remapped = []
        self.on_cursor = None      # callback()
        self.on_clipboard = None   # callback(owner_window)
        self.on_resize = None      # callback(w, h)
        self.size = self.screen_size()

    # ---------------------------------------------------------------- events
    def watch(self, loop):
        """Subscribe to change notifications and read them from the asyncio loop."""
        XSelectInput(self.dpy, self.root, StructureNotifyMask)
        if self.fixes_event >= 0:
            XFixesSelectCursorInput(self.dpy, self.root, XFixesDisplayCursorNotifyMask)
            XFixesSelectSelectionInput(self.dpy, self.root, self.clipboard_atom, XFixesSetSelectionOwnerNotifyMask)
        XFlush(self.dpy)
        loop.add_reader(XConnectionNumber(self.dpy), self._drain)

    def unwatch(self, loop):
        try:
            loop.remove_reader(XConnectionNumber(self.dpy))
        except Exception:
            pass

    def _drain(self):
        ev = _XEvent()
        while XPending(self.dpy):
            XNextEvent(self.dpy, ctypes.byref(ev))
            etype = ev[0] & 0x7F
            try:
                if etype == ConfigureNotify:
                    ce = ctypes.cast(ctypes.byref(ev), ctypes.POINTER(_XConfigureEvent)).contents
                    if ce.window == self.root and (ce.width, ce.height) != self.size:
                        self.size = (ce.width, ce.height)
                        if self.on_resize:
                            self.on_resize(ce.width, ce.height)
                elif self.fixes_event >= 0 and etype == self.fixes_event + 1:
                    if self.on_cursor:
                        self.on_cursor()
                elif self.fixes_event >= 0 and etype == self.fixes_event:
                    se = ctypes.cast(ctypes.byref(ev), ctypes.POINTER(_XFixesSelectionNotifyEvent)).contents
                    if se.selection == self.clipboard_atom and self.on_clipboard:
                        self.on_clipboard(se.owner)
            except Exception:
                log.exception("X event handler failed")

    def screen_size(self):
        r = _Window()
        x, y = ctypes.c_int(), ctypes.c_int()
        w, h, bw, dp = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
        XGetGeometry(self.dpy, self.root, ctypes.byref(r), ctypes.byref(x), ctypes.byref(y),
                     ctypes.byref(w), ctypes.byref(h), ctypes.byref(bw), ctypes.byref(dp))
        return w.value, h.value

    # ---------------------------------------------------------------- cursor
    def cursor_image(self):
        """(serial, w, h, xhot, yhot, rgba_bytes) of the current pointer, straight RGBA."""
        p = XFixesGetCursorImage(self.dpy)
        if not p:
            return None
        try:
            ci = p.contents
            w, h = ci.width, ci.height
            n = w * h
            px = ctypes.cast(ci.pixels, ctypes.POINTER(ctypes.c_ulong * n)).contents if n else []
            out = bytearray(n * 4)
            visible = False
            for i, v in enumerate(px):
                a = (v >> 24) & 0xFF
                if not a:
                    continue
                visible = True
                r, g, b = (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF
                if a != 255:  # XFixes gives premultiplied alpha
                    r, g, b = min(255, r * 255 // a), min(255, g * 255 // a), min(255, b * 255 // a)
                j = i * 4
                out[j], out[j + 1], out[j + 2], out[j + 3] = r, g, b, a
            return ci.cursor_serial & 0xFFFFFFFF, w, h, ci.xhot, ci.yhot, bytes(out) if visible else None
        finally:
            XFree(p)

    # ---------------------------------------------------------------- input
    def motion(self, x, y):
        XTestFakeMotionEvent(self.dpy, -1, x, y, 0)
        XFlush(self.dpy)

    def button(self, xbutton, down):
        XTestFakeButtonEvent(self.dpy, xbutton, 1 if down else 0, 0)
        XFlush(self.dpy)

    def key(self, keycode, down):
        XTestFakeKeyEvent(self.dpy, keycode, 1 if down else 0, 0)
        XFlush(self.dpy)

    def wheel(self, xbutton, clicks):
        for _ in range(clicks):
            XTestFakeButtonEvent(self.dpy, xbutton, 1, 0)
            XTestFakeButtonEvent(self.dpy, xbutton, 0, 0)
        XFlush(self.dpy)

    def autorepeat(self):
        st = _XKeyboardState()
        XGetKeyboardControl(self.dpy, ctypes.byref(st))
        return bool(st.global_auto_repeat)

    def set_autorepeat(self, on):
        (XAutoRepeatOn if on else XAutoRepeatOff)(self.dpy)
        XFlush(self.dpy)

    # ---------------------------------------------------------------- text typing
    def _find_spare_keycodes(self, want=8):
        """Keycodes with no symbols; we borrow them to type characters the layout lacks."""
        per = ctypes.c_int()
        count = self.max_kc - self.min_kc + 1
        m = XGetKeyboardMapping(self.dpy, self.min_kc, count, ctypes.byref(per))
        spare = []
        if m:
            for i in range(count):
                if all(m[i * per.value + j] == 0 for j in range(per.value)):
                    spare.append(self.min_kc + i)
            XFree(m)
        return spare[-want:]

    @staticmethod
    def _keysym(ch):
        o = ord(ch)
        if ch == "\n":
            return 0xFF0D
        if ch == "\t":
            return 0xFF09
        if 0x20 <= o <= 0x7E or 0xA0 <= o <= 0xFF:
            return o
        return 0x01000000 | o

    def type_text(self, text, shift_keycode):
        """Type arbitrary Unicode. Characters on the current layout use their real key;
        others are typed through a temporarily remapped spare keycode."""
        pending = []
        for ch in text:
            ks = self._keysym(ch)
            kc = XKeysymToKeycode(self.dpy, ks)
            if kc:
                if XKeycodeToKeysym(self.dpy, kc, 0) == ks:
                    pending.append((kc, False))
                    continue
                if XKeycodeToKeysym(self.dpy, kc, 1) == ks:
                    pending.append((kc, True))
                    continue
            if not self._spare:
                continue
            self._flush_typed(pending, shift_keycode)
            pending = []
            kc = self._spare[len(self._remapped) % len(self._spare)]
            arr = (_KeySym * 2)(ks, ks)
            XChangeKeyboardMapping(self.dpy, kc, 2, arr, 1)
            XSync(self.dpy, 0)
            self._remapped.append(kc)
            pending.append((kc, False))
        self._flush_typed(pending, shift_keycode)

    def _flush_typed(self, keys, shift_keycode):
        for kc, shift in keys:
            if shift:
                XTestFakeKeyEvent(self.dpy, shift_keycode, 1, 0)
            XTestFakeKeyEvent(self.dpy, kc, 1, 0)
            XTestFakeKeyEvent(self.dpy, kc, 0, 0)
            if shift:
                XTestFakeKeyEvent(self.dpy, shift_keycode, 0, 0)
        XFlush(self.dpy)

    def restore_keymap(self):
        """Give borrowed keycodes back (call a moment after typing, once apps have read them)."""
        if not self._remapped:
            return
        empty = (_KeySym * 2)(0, 0)
        for kc in set(self._remapped):
            XChangeKeyboardMapping(self.dpy, kc, 2, empty, 1)
        self._remapped.clear()
        XFlush(self.dpy)

    def close(self):
        if self.dpy:
            XCloseDisplay(self.dpy)
            self.dpy = None
