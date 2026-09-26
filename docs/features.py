#!/usr/bin/env python3
"""Generates the README's feature animations (docs/feature-*.svg). Each one is the same scene, the
Linux computer on the left and the Mac on the right, joined by the private link, with one feature
animated in it. Pure SVG and CSS (no scripts, fonts or images), so they play inside a GitHub README.
Usage: python3 docs/features.py [out-dir]"""
import os
import sys

W, H = 300, 146
UI = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
MONO = "ui-monospace,'SF Mono',Menlo,Consolas,'DejaVu Sans Mono',monospace"
ADV = 0.6                                  # monospace advance (em)

TX, TY, TW, TH = 16, 40, 36, 60            # the Linux computer
MX, MY, MW, MH = 104, 12, 182, 117         # the Mac's display, bezel included, in the Mac's own units
SX, SY, SW, SH = 108, 16, 174, 109         # its screen
MAC_S, MAC_T = 0.9, (28.6, 7.0)            # the Mac is drawn at 90 %: x' = 28.6 + 0.9 x, y' = 7 + 0.9 y
LINK_Y, LA = 70, 56                        # the link: height, Linux end
LB = round(MAC_T[0] + MAC_S * MX) - 3      # its Mac end, just before the Mac

DEFS = (
    '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#141b3d"/>'
    '<stop offset=".6" stop-color="#2d2466"/><stop offset="1" stop-color="#5a2f6e"/></linearGradient>'
    '<linearGradient id="lin" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2c0f2a"/>'
    '<stop offset=".6" stop-color="#6b1d4b"/><stop offset="1" stop-color="#c2462f"/></linearGradient>'
    '<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2b4fc2"/>'
    '<stop offset=".55" stop-color="#6a4fd0"/><stop offset="1" stop-color="#b45fc8"/></linearGradient>'
    '<radialGradient id="glow1"><stop offset="0" stop-color="#ff9ad5" stop-opacity=".6"/>'
    '<stop offset="1" stop-color="#ff9ad5" stop-opacity="0"/></radialGradient>'
    '<radialGradient id="glow2"><stop offset="0" stop-color="#7cd3ff" stop-opacity=".55"/>'
    '<stop offset="1" stop-color="#7cd3ff" stop-opacity="0"/></radialGradient>'
    '<linearGradient id="alu" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e6e8ec"/>'
    '<stop offset="1" stop-color="#a4a8b1"/></linearGradient>'
    '<filter id="sh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="1.2" '
    'stdDeviation="1.4" flood-color="#000" flood-opacity=".35"/></filter>'
    f'<clipPath id="scr"><rect x="{SX}" y="{SY}" width="{SW}" height="{SH}"/></clipPath>')


class Scene:
    def __init__(self, T=6.0):
        self.T, self.css, self.defs, self.body = T, [], [], []

    def add(self, *parts):
        self.body.extend(parts)

    def anim(self, cls, frames, timing="linear", extra=""):
        pct = lambda t: "%.2f%%" % (100 * min(max(t, 0), self.T) / self.T)
        ks = "".join(pct(t) + "{" + p + "}" for t, p in frames)
        self.css.append("@keyframes %s{%s}.%s{animation:%s %gs %s infinite;%s}" % (cls, ks, cls, cls, self.T, timing, extra))

    def show(self, cls, on, off=None, fade=0.15):
        """Visible from `on` to `off` (seconds), fading in and out."""
        off = self.T if off is None else off
        f = [(0, "opacity:0"), (on, "opacity:0"), (on + fade, "opacity:1")] if on > 0 else [(0, "opacity:1")]
        f += [(off, "opacity:1"), (off + fade, "opacity:0"), (self.T, "opacity:0")] if off < self.T else [(self.T, "opacity:1")]
        self.anim(cls, f)

    def move(self, cls, points, fade=0.1):
        """Travels through (t, x, y) points, fading in at the first and out at the last."""
        tr = lambda x, y: "transform:translate(%.1fpx,%.1fpx)" % (x, y)
        (t0, x0, y0), (t1, x1, y1) = points[0], points[-1]
        f = [(0, "opacity:0;" + tr(x0, y0)), (t0, "opacity:0;" + tr(x0, y0)), (t0 + fade, "opacity:1;" + tr(x0, y0))]
        f += [(t, "opacity:1;" + tr(x, y)) for t, x, y in points[1:-1]]
        f += [(t1 - fade, "opacity:1;" + tr(x1, y1)), (t1, "opacity:0;" + tr(x1, y1)), (self.T, "opacity:0;" + tr(x1, y1))]
        self.anim(cls, f, "ease-in-out")

    def svg(self, label):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
                f'aria-label="{label}"><title>{label}</title><style>' + "".join(self.css)
                + '@media (prefers-reduced-motion:reduce){*{animation-play-state:paused!important}}</style>'
                + f'<defs>{DEFS}{"".join(self.defs)}</defs>' + "".join(self.body) + '</svg>')


# ------------------------------------------------------------------------------------ drawing

def text(x, y, s, size=7, fill="#fff", anchor="start", weight=400, font=UI, cls="", length=None, opacity=None):
    a = f' class="{cls}"' if cls else ""
    if length:
        a += f' textLength="{length:.1f}" lengthAdjust="spacing"'
    if anchor != "start":
        a += f' text-anchor="{anchor}"'
    if weight != 400:
        a += f' font-weight="{weight}"'
    if opacity is not None:
        a += f' fill-opacity="{opacity}"'
    return (f'<text{a} x="{x:.1f}" y="{y:.1f}" font-family="{font}" font-size="{size}" fill="{fill}" '
            f'xml:space="preserve">{s}</text>')


def mono(x, y, s, size=7, fill="#e6e6e6", **kw):
    return text(x, y, s, size, fill, font=MONO, **kw)


def backdrop(s):
    s.add(f'<rect width="{W}" height="{H}" rx="12" fill="url(#bg)"/>')


def tower(s, gpu_cls=""):
    x, y, w, h = TX, TY, TW, TH
    s.add(f'<rect x="{x + 4}" y="{y + h - 1}" width="7" height="3" rx="1" fill="#2a2b33"/>',
          f'<rect x="{x + w - 11}" y="{y + h - 1}" width="7" height="3" rx="1" fill="#2a2b33"/>',
          f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" fill="#1c1d24" stroke="#555966"/>',
          f'<rect x="{x + 5}" y="{y + 5}" width="{w - 10}" height="11" rx="1.5" fill="#2a2b33"/>',
          f'<circle cx="{x + w / 2}" cy="{y + 10.5}" r="2" fill="#5ad16a"/>')
    for i in range(4):
        s.add(f'<rect x="{x + 8}" y="{y + 23 + i * 5}" width="{w - 16}" height="1.6" rx=".8" fill="#393b45"/>')
    s.add(f'<rect class="{gpu_cls}" x="{x + 6}" y="{y + h - 11}" width="{w - 12}" height="3" rx="1.5" fill="#76b900"/>',
          text(x + w / 2, y + h + 16, "Linux", 9.5, "#fff", "middle", opacity=.8))


def link(s, cls=""):
    c = (LA + LB) / 2
    s.add(f'<g class="{cls}"><line x1="{LA}" y1="{LINK_Y}" x2="{LB}" y2="{LINK_Y}" stroke="#fff" stroke-opacity=".5" '
          'stroke-width="1.4" stroke-dasharray="3 3"/>'
          f'<g transform="translate({c} {LINK_Y - 15})"><rect x="-6.5" y="-4" width="13" height="10" rx="2.5" fill="#fff"/>'
          '<path d="M-3.6-4v-2.2a3.6 3.6 0 0 1 7.2 0V-4" fill="none" stroke="#fff" stroke-width="1.6"/>'
          '<circle cy=".6" r="1.4" fill="#3b2e87"/><rect x="-.6" y=".6" width="1.2" height="2.8" rx=".5" fill="#3b2e87"/></g></g>')


def mac(s, content="", over=""):
    """A MacBook running macOS: aluminium rim, notch, menu bar and Dock. `content` (windows) is drawn
    on the screen under the Dock and menu bar; `over` floats on top (keys pressed, the pointer).
    Both use the Mac's own units; the whole Mac is drawn at 90 %."""
    notch = SX + SW / 2 - 11
    menu = (f'<rect x="{SX}" y="{SY}" width="{SW}" height="6" fill="#fff" fill-opacity=".22"/>'
            + text(SX + 6, SY + 4.4, "Darpan", 3.9, "#fff", weight=700)
            + "".join(text(SX + x, SY + 4.4, w, 3.9, "#fff") for x, w in ((25, "File"), (34.5, "Edit"), (44, "View"), (54, "Window")))
            + f'<g fill="none" stroke="#fff" stroke-width=".6" stroke-linecap="round" transform="translate({SX + SW - 34} {SY + 4.3})">'
              '<path d="M-2.4-1.6a3.4 3.4 0 0 1 4.8 0"/><path d="M-1.3-.5a1.8 1.8 0 0 1 2.6 0"/></g>'
            + f'<circle cx="{SX + SW - 34}" cy="{SY + 4.4}" r=".45" fill="#fff"/>'
            + f'<rect x="{SX + SW - 27}" y="{SY + 1.9}" width="7" height="3.3" rx=".9" fill="none" stroke="#fff" stroke-width=".5"/>'
            + f'<rect x="{SX + SW - 26.2}" y="{SY + 2.7}" width="4.6" height="1.7" rx=".4" fill="#fff"/>'
            + text(SX + SW - 5, SY + 4.4, "9:41", 3.9, "#fff", "end", 600)
            + f'<path d="M{notch} {SY}h22v3a2 2 0 0 1-2 2h-18a2 2 0 0 1-2-2z" fill="#0e0e11"/>')
    icons = ("#2f8cff", "#34c759", "#ff9f0a", "#bf5af2", "#ff453a", "#64d2ff")
    dw = (len(icons) + 1) * 9 - 2.6 + 6
    dx, dy = SX + SW / 2 - dw / 2, SY + SH - 11.4
    dock = (f'<rect x="{dx:.1f}" y="{dy:.1f}" width="{dw:.1f}" height="9.4" rx="3.2" fill="#fff" fill-opacity=".22" '
            'stroke="#fff" stroke-opacity=".35" stroke-width=".4"/>'
            + "".join(f'<rect x="{dx + 3 + i * 9:.1f}" y="{dy + 1.5:.1f}" width="6.4" height="6.4" rx="1.6" fill="{c}"/>'
                      for i, c in enumerate(icons))
            + f'<circle cx="{dx + 3 + len(icons) * 9 + 3.2:.1f}" cy="{dy + 4.7:.1f}" r="3" fill="#1d2a6b" stroke="#e8b04a" stroke-width=".9"/>'
            + f'<circle cx="{dx + 3 + len(icons) * 9 + 3.2:.1f}" cy="{dy + 8.6:.1f}" r=".5" fill="#fff"/>')
    wall = (f'<rect x="{SX}" y="{SY}" width="{SW}" height="{SH}" fill="url(#wall)"/>'
            f'<ellipse cx="{SX + 30}" cy="{SY + SH - 10}" rx="95" ry="45" fill="url(#glow1)"/>'
            f'<ellipse cx="{SX + SW - 25}" cy="{SY + 25}" rx="80" ry="40" fill="url(#glow2)"/>')
    s.add(f'<g transform="translate({MAC_T[0]} {MAC_T[1]}) scale({MAC_S})">',
          f'<rect x="{MX - 1.2}" y="{MY - 1.2}" width="{MW + 2.4}" height="{MH + 1.2}" rx="8" fill="#b9bdc6"/>',
          f'<rect x="{MX}" y="{MY}" width="{MW}" height="{MH}" rx="7" fill="#0e0e11"/>',
          f'<g clip-path="url(#scr)">{wall}{content}{dock}{menu}</g>',
          f'<path d="M{MX - 7} {MY + MH}h{MW + 14}l-3.5 6h{-(MW + 7)}z" fill="url(#alu)"/>',
          f'<rect x="{MX + MW / 2 - 12}" y="{MY + MH}" width="24" height="2" rx="1" fill="#9a9ea8"/>',
          over, '</g>')


def viewer(s, x, y, w, inner="", cls=""):
    """Darpan's window on the Mac, showing the Linux desktop; `inner` is in the desktop's coordinates."""
    h, tb = round(w * 9 / 16, 2), 7
    s.defs.append(f'<clipPath id="vc"><path d="M0 0H{w}V{h - 3}a3 3 0 0 1-3 3H3a3 3 0 0 1-3-3z"/></clipPath>')
    lights = "".join(f'<circle cx="{x + 5.5 + i * 4.5}" cy="{y + 3.5}" r="1.5" fill="{c}"/>'
                     for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")))
    return (f'<g class="{cls}"><rect x="{x}" y="{y}" width="{w}" height="{h + tb}" rx="3.5" fill="#111" filter="url(#sh)"/>'
            f'<path d="M{x} {y + tb}v-3.5a3.5 3.5 0 0 1 3.5-3.5h{w - 7}a3.5 3.5 0 0 1 3.5 3.5v3.5z" fill="#e8e8ec"/>{lights}'
            f'<g transform="translate({x} {y + tb})"><g clip-path="url(#vc)"><rect width="{w}" height="{h}" fill="url(#lin)"/>'
            f'<rect width="{w}" height="3.5" fill="#0b0b0d"/>{inner}</g></g></g>')


def window(x, y, w, h, body, bar, inner=""):
    """A window with a 5-unit title bar (terminals, the file manager)."""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="2.5" fill="{body}"/>'
            f'<path d="M{x} {y + 5}v-2.5a2.5 2.5 0 0 1 2.5-2.5h{w - 5}a2.5 2.5 0 0 1 2.5 2.5v2.5z" fill="{bar}"/>{inner}')


def term(x, y, w, h, inner=""):
    return window(x, y, w, h, "#1e1a23", "#3a3640", inner)


def training(x, y, w, h, bar_cls, size=8):
    """A terminal running a training job, its progress bar animated by `bar_cls`."""
    col = x + 5
    return term(x, y, w, h,
                mono(col, y + 15, "$", size, "#8ae234") + mono(col + 2 * size * ADV, y + 15, "python train.py", size)
                + mono(col, y + 26, "epoch 2/3", size, "#7fd1ff")
                + f'<rect x="{col}" y="{y + 31}" width="{w - 10}" height="4" rx="2" fill="#fff" fill-opacity=".15"/>'
                + f'<rect class="{bar_cls}" x="{col}" y="{y + 31}" width="{w - 10}" height="4" rx="2" fill="#8ae234"/>')


def keycap(cx, cy, label, cls):
    return (f'<g class="{cls}"><rect x="{cx - 11}" y="{cy - 6.5}" width="22" height="13" rx="3" fill="#fff" filter="url(#sh)"/>'
            + text(cx, cy + 2.9, label, 8, "#1d1d1f", "middle", 600) + '</g>')


def doc(cls, opacity=1):
    return (f'<g class="{cls}"><g opacity="{opacity}"><rect x="-5" y="-6.5" width="10" height="13" rx="1.5" fill="#fff" '
            'filter="url(#sh)"/><path d="M-2.8-2.5h5.6M-2.8 .5h5.6M-2.8 3.5h3.6" stroke="#3b2e87" stroke-width="1"/></g></g>')


def pdf(x, y, cls="", opacity=1):
    """A PDF file icon centred on (x, y)."""
    c = f' class="{cls}"' if cls else ""
    return (f'<g{c} opacity="{opacity}"><rect x="{x - 6}" y="{y - 7.5}" width="12" height="15" rx="1.5" fill="#fff" filter="url(#sh)"/>'
            f'<rect x="{x - 6}" y="{y + 0.5}" width="12" height="4.5" fill="#e5484d"/>'
            + text(x, y + 4, "PDF", 3.6, "#fff", "middle", 700) + '</g>')


def dot(cls, fill="#fff", r=2):
    return f'<circle class="{cls}" r="{r}" fill="{fill}"/>'


def packets(s, times, dur=0.45, prefix="pk"):
    """White dots along the link: (start time, towards Linux?)."""
    for i, (t, to_linux) in enumerate(times):
        a, b = (LB, LA) if to_linux else (LA, LB)
        s.add(dot(f"{prefix}{i}"))
        s.move(f"{prefix}{i}", [(t, a, LINK_Y), (t + dur, b, LINK_Y)], fade=0.05)


def grow(s, cls, frames):
    """A bar that fills from the left: (t, fraction) frames."""
    s.anim(cls, [(t, "transform:scaleX(%.3f)" % f) for t, f in frames], extra="transform-box:fill-box;transform-origin:0 0")


# ------------------------------------------------------------------------------------ scenes

def feels_local():
    s = Scene(6.0)
    backdrop(s)
    tower(s)
    link(s)
    size, adv = 8, 8 * ADV
    col = lambda n: 14 + n * adv                          # the terminal's columns (desktop coordinates)
    l1, l2, l3, l4 = 23, 34, 45, 56
    cmd, t0, dt = "nvidia-smi", 0.9, 0.18
    enter = t0 + len(cmd) * dt + 0.2
    inner = [mono(col(0), l1, "$", size, "#8ae234")]
    inner += [mono(col(2 + i), l1, ch, size, cls=f"k{i}") for i, ch in enumerate(cmd)]
    inner += ['<g class="out">', mono(col(0), l2, "NVIDIA RTX 4090", size, "#7fd1ff"),
              mono(col(0), l3, "41°C    3 %   250 MiB", size), mono(col(0), l4, "$", size, "#8ae234"), '</g>',
              f'<rect class="cur" x="{col(2):.1f}" y="{l1 - 6.6}" width="{adv - .4:.1f}" height="8.2" fill="#e6e6e6" fill-opacity=".85"/>']
    mac(s, viewer(s, 125, 26, 140, term(8, 8, 124, 56, "".join(inner))))
    for i in range(len(cmd)):
        s.show(f"k{i}", t0 + i * dt, 5.6, 0.01)
    s.show("out", enter + 0.08, 5.6, 0.02)
    steps = [(0, 0, 0)] + [(t0 + i * dt, (i + 1) * adv, 0) for i in range(len(cmd))] + [(enter + 0.08, 0, l4 - l1), (5.75, 0, 0)]
    s.anim("cur", [(t, "transform:translate(%.1fpx,%dpx)" % (x, y)) for t, x, y in steps] + [(6, "transform:translate(0,0)")],
           "step-end")
    for i, t in enumerate([t0 + i * dt for i in range(len(cmd))] + [enter]):   # each key travels to Linux
        s.add(dot(f"p{i}"))
        s.move(f"p{i}", [(t - 0.16, LB, LINK_Y), (t, LA, LINK_Y)], fade=0.03)
    c = (LA + LB) / 2
    s.add(f'<rect x="{c - 16}" y="{LINK_Y + 9}" width="32" height="13" rx="6.5" fill="#fff"/>',
          text(c, LINK_Y + 18.4, "27 ms", 8, "#3b2e87", "middle", 700))
    return s.svg("Typing on the Mac: each key reaches the Linux computer and its screen is back on the Mac in about 27 ms")


def private():
    s = Scene(6.0)
    backdrop(s)
    tower(s)
    s.add(f'<line x1="{LA}" y1="{LINK_Y}" x2="{LB}" y2="{LINK_Y}" stroke="#7ee787" stroke-opacity=".8" stroke-width="3" '
          'stroke-linecap="round"/>')
    link(s)
    mac(s, viewer(s, 125, 26, 140, training(8, 8, 124, 44, "bar")))
    grow(s, "bar", [(0, .35), (6, .75)])
    packets(s, [(0.2 + i, True) for i in range(5)] + [(0.7 + i, False) for i in range(5)])
    # someone else's device tries to reach the Linux computer and is refused
    s.add('<g class="who"><rect x="66" y="14" width="24" height="15" rx="2" fill="#5f636e"/>'
          '<rect x="68" y="16" width="20" height="11" fill="#2b2d34"/>'
          + text(78, 25, "?", 9, "#ff6b6b", "middle", 700)
          + '<path d="M62 29h32l-2.5 3.5h-27z" fill="#8b8f99"/></g>')
    s.show("who", 0.8, 4.4, 0.25)
    s.add(dot("probe", "#ff5f57", 2.2))
    s.move("probe", [(1.7, 71, 34), (2.4, 60, 42)], fade=0.08)
    s.add('<g class="deny"><g transform="translate(57 44)"><path d="M0-7l6 2.3V0c0 4-2.6 6.2-6 7.2C-3.4 6.2-6 4-6 0v-4.7z" '
          'fill="#ff5f57" stroke="#fff" stroke-width="1"/><path d="M-2.2-2.2l4.4 4.4M2.2-2.2l-4.4 4.4" stroke="#fff" '
          'stroke-width="1.4" stroke-linecap="round"/></g></g>')
    s.show("deny", 2.35, 3.8, 0.1)
    return s.svg("Only your own devices reach the Linux computer, over an encrypted link; another device is refused")


def light():
    s = Scene(8.0)
    backdrop(s)
    tower(s, "gpu")
    s.anim("gpu", [(t / 2, "opacity:%s" % (".55" if t % 2 else "1")) for t in range(17)])
    link(s, "ln")
    mac(s, viewer(s, 125, 26, 140, training(8, 8, 124, 44, "bar"), "vw"))
    grow(s, "bar", [(0, .3), (8, .7)])
    on, off = 3.2, 6.3                              # the Mac disconnects, then connects again
    s.anim("vw", [(0, "opacity:1"), (on, "opacity:1"), (on + .3, "opacity:0"), (off, "opacity:0"), (off + .3, "opacity:1"), (8, "opacity:1")])
    s.anim("ln", [(0, "opacity:1"), (on, "opacity:1"), (on + .3, "opacity:.3"), (off, "opacity:.3"), (off + .3, "opacity:1"), (8, "opacity:1")])
    packets(s, [(0.2, True), (0.7, False), (1.2, True), (1.7, False), (2.2, True), (2.7, False), (6.7, True), (7.2, False)])
    for i, (label, fill) in enumerate((("GPU", "#9be15d"), ("Darpan", "#fff"))):
        y = 6 + i * 15
        s.add(f'<rect x="10" y="{y}" width="86" height="12" rx="6" fill="#0b0d1a" fill-opacity=".55" stroke="#fff" stroke-opacity=".15"/>',
              text(17, y + 8.6, label, 7.5, "#fff", opacity=.75))
    s.add(text(89, 14.6, "100 %", 7.5, "#9be15d", "end", 700),
          text(89, 29.6, "0.3 %", 7.5, "#fff", "end", 700, cls="v1"),
          text(89, 29.6, "0 %", 7.5, "#fff", "end", 700, cls="v0"))
    s.anim("v1", [(0, "opacity:1"), (on, "opacity:1"), (on + .15, "opacity:0"), (off + .15, "opacity:0"), (off + .3, "opacity:1"), (8, "opacity:1")])
    s.anim("v0", [(0, "opacity:0"), (on + .15, "opacity:0"), (on + .3, "opacity:1"), (off, "opacity:1"), (off + .15, "opacity:0"), (8, "opacity:0")])
    return s.svg("Darpan uses about 0.3 percent CPU on the Linux computer while you're connected and none after you disconnect; the GPU stays with your training job")


def sound():
    s = Scene(6.0)
    backdrop(s)
    tower(s)
    link(s)
    bars = []
    for i in range(7):
        x = 39.5 + i * 8
        bars.append(f'<rect class="eq{i}" x="{x}" y="26" width="5" height="26" rx="1.5" fill="#fff" fill-opacity=".85"/>')
        lv = [(.25, .9), (.6, .3), (.35, 1), (.8, .45), (.3, .75), (.9, .35), (.5, .8)][i]
        s.anim(f"eq{i}", [(k * .3, "transform:scaleY(%.2f)" % lv[k % 2]) for k in range(21)],
               extra="transform-box:fill-box;transform-origin:50% 100%")
    video = (f'<rect x="10" y="8" width="112" height="63" rx="2" fill="#0c0c0f"/>{"".join(bars)}'
             '<rect x="16" y="62" width="100" height="2" rx="1" fill="#fff" fill-opacity=".25"/>'
             '<rect class="prog" x="16" y="62" width="100" height="2" rx="1" fill="#ff3b30"/>')
    grow(s, "prog", [(0, .2), (6, .8)])
    speaker = ('<g transform="translate(262 70)"><path d="M-7-2.5h3l4-3.5v12l-4-3.5h-3z" fill="#fff"/>'
               '<path class="w1" d="M3-3.3a4.6 4.6 0 0 1 0 6.6" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
               '<path class="w2" d="M5.6-6.2a8.8 8.8 0 0 1 0 12.4" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/></g>')
    mac(s, viewer(s, 114, 27, 132, video) + speaker)
    for k, cls in enumerate(("w1", "w2")):
        s.anim(cls, [(t / 2 + k * .15, "opacity:%s" % ("1" if t % 2 else ".2")) for t in range(12)] + [(6, "opacity:.2")])
    note = ('<g class="n{i}"><ellipse cx="0" cy="3" rx="2.9" ry="2.1" transform="rotate(-20)" fill="#fff"/>'
            '<path d="M2.4 2.4V-7c1.5 1.8 4 2.6 3.6 5.6" fill="none" stroke="#fff" stroke-width="1.3" stroke-linecap="round"/></g>')
    for i in range(3):
        t = 0.2 + i * 2.0
        s.add(note.format(i=i))
        s.move(f"n{i}", [(t, LA + 2, LINK_Y + 8), (t + .7, (LA + LB) / 2, LINK_Y + 11), (t + 1.4, LB + 4, LINK_Y + 8)])
    return s.svg("A video plays on the Linux computer and its sound comes out of the Mac")


def clipboard():
    s = Scene(6.0)
    backdrop(s)
    tower(s)
    link(s)
    size, adv = 7, 7 * ADV
    col = lambda n: 10 + n * adv
    terminal = term(5, 7, 98, 48,
                    mono(col(0), 21, "loss  0.398", size)
                    + f'<rect class="sel1" x="{col(6) - .6:.1f}" y="25" width="{5 * adv + 1.2:.1f}" height="8" fill="#3f6fd8"/>'
                    + mono(col(0), 31, "acc", size) + mono(col(6), 31, "87.8%", size, length=5 * adv)
                    + mono(col(0), 41, "$", size, "#8ae234")
                    + mono(col(2), 41, "nvidia-smi", size, cls="paste2", length=10 * adv)
                    + f'<rect class="cur" x="{col(2):.1f}" y="35" width="{adv - .4:.1f}" height="7.6" fill="#e6e6e6" fill-opacity=".85"/>')
    nx, ny = 226, 34
    notes = (f'<rect x="{nx}" y="{ny}" width="52" height="58" rx="3" fill="#fdfdfd" filter="url(#sh)"/>'
             f'<path d="M{nx} {ny + 7}v-4a3 3 0 0 1 3-3h46a3 3 0 0 1 3 3v4z" fill="#ececf0"/>'
             + "".join(f'<circle cx="{nx + 5 + i * 4}" cy="{ny + 3.5}" r="1.3" fill="{c}"/>'
                       for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")))
             + text(nx + 5, ny + 18, "Results", 7, "#1d1d1f", weight=700)
             + text(nx + 5, ny + 29, "acc:", 7, "#1d1d1f")
             + text(nx + 20, ny + 29, "87.8%", 7, "#1d1d1f", cls="paste1", length=20)
             + f'<rect class="sel2" x="{nx + 4.4}" y="{ny + 38.2}" width="39.2" height="8.4" fill="#b3d4ff"/>'
             + text(nx + 5, ny + 44.6, "nvidia-smi", 7, "#1d1d1f", length=38))
    keys = (keycap(166, 27, "⌘C", "c1") + keycap(nx + 31, ny + 1, "⌘V", "v1")
            + keycap(nx + 31, ny + 1, "⌘C", "c2") + keycap(166, 27, "⌘V", "v2"))
    mac(s, viewer(s, 112, 26, 108, terminal) + notes, keys)
    s.show("sel1", 0.4, 2.5, 0.08)
    s.show("c1", 0.7, 1.4, 0.1)
    s.add(doc("d1"))
    s.move("d1", [(1.0, LA, LINK_Y), (1.8, LB, LINK_Y)])
    s.show("v1", 1.8, 2.5, 0.1)
    s.show("paste1", 2.0, 5.6, 0.05)
    s.show("sel2", 2.9, 4.9, 0.08)
    s.show("c2", 3.1, 3.8, 0.1)
    s.add(doc("d2"))
    s.move("d2", [(3.4, LB, LINK_Y), (4.2, LA, LINK_Y)])
    s.show("v2", 4.2, 4.9, 0.1)
    s.show("paste2", 4.4, 5.6, 0.05)
    s.anim("cur", [(0, "transform:translateX(0)"), (4.4, "transform:translateX(%.1fpx)" % (10 * adv)), (5.75, "transform:translateX(0)"),
                   (6, "transform:translateX(0)")], "step-end")
    return s.svg("Text copied with Command-C in a Linux terminal pastes into a Mac app, and text copied on the Mac pastes into the terminal")


def files():
    s = Scene(6.0)
    backdrop(s)
    tower(s)
    link(s)
    linux = ('<g class="landed">' + pdf(14, 16) + text(14, 29.5, "report.pdf", 5, "#fff", "middle", 600) + '</g>'
             + '<g class="toast"><rect x="30" y="54" width="60" height="9" rx="4.5" fill="#000" fill-opacity=".55"/>'
             + '<rect x="35" y="57.5" width="50" height="2" rx="1" fill="#fff" fill-opacity=".25"/>'
             + '<rect class="tbar" x="35" y="57.5" width="50" height="2" rx="1" fill="#5aa0ff"/></g>'
             + '<rect class="drop" x="1" y="1" width="118" height="65.5" fill="none" stroke="#5aa0ff" stroke-width="2"/>')
    desktop = pdf(257, 58) + text(257, 74, "report.pdf", 5.5, "#fff", "middle", 600)
    mac(s, viewer(s, 112, 26, 120, linux) + desktop,
        '<g class="drag">' + pdf(0, 0, opacity=.8) + '</g>'
        '<path class="ptr" d="M0 0v10.5l2.5-2.3 1.7 4 1.8-.8-1.7-3.9h3.4z" fill="#000" stroke="#fff" stroke-width=".8"/>')
    s.move("ptr", [(0.3, 262, 60), (0.7, 262, 60), (1.6, 176, 64), (2.2, 176, 64)])
    s.move("drag", [(0.7, 257, 58), (1.6, 171, 62), (1.95, 171, 62)])
    s.show("drop", 1.35, 1.9, 0.1)
    s.add(doc("d1"))
    s.move("d1", [(1.9, LB, LINK_Y), (2.7, LA, LINK_Y)])
    s.show("toast", 1.9, 2.9, 0.1)
    grow(s, "tbar", [(0, 0), (1.9, 0), (2.8, 1), (6, 1)])
    s.show("landed", 2.9, 5.6)
    return s.svg("A file dragged from the Mac desktop onto Darpan's window lands on the Linux desktop")


FEATURES = {"local": feels_local, "private": private, "light": light, "sound": sound, "clipboard": clipboard, "files": files}

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    for name, make in FEATURES.items():
        path = os.path.join(out, f"feature-{name}.svg")
        svg = make()
        with open(path, "w") as f:
            f.write(svg)
        print(f"{path}: {len(svg.encode()) / 1024:.1f} KB")
