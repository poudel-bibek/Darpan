#!/usr/bin/env python3
"""Generates docs/onboarding-linux.webp and docs/onboarding-mac.webp, the first run on each computer, and a
still of each for reduced motion. Both are the same size and show Darpan's windows on that computer's
desktop, drawn like demo.svg. Animated WebP, not GIF: the wallpapers' gradients need more than 256
colours, and WebP keeps them smooth at a fraction of the size.

The windows come from <shots>, sample data only, at 1x (points):
  linux-1..4.png  the Darpan window on Linux: Welcome, finishing the sign-in in the browser, the click
                  that allows secure addresses, and You're set (GDK_SCALE=2 on a private X display, halved)
  mac-1..5.png    the Mac, in the dark appearance (screencapture -x -o -l <window>, halved): the disk
                  image window; Welcome, from a debug build with DARPAN_DEBUG_DEMO=1 DARPAN_DEBUG_WELCOME=1;
                  your computers, with DARPAN_DEBUG_DEMO=1; the password, after the debug commands
                  `pick https://workstation.example.ts.net` and `typepw …`; and the upper right of a window
                  connected to `FakeHost --name workstation --image desktop.png`
                  (mac/tools/onboarding-gif/desktop.py), with the toolbar tip
Needs Pillow and librsvg (PyGObject). Usage: python3 docs/onboarding.py <shots> [out-dir]"""
import os
import re
import sys
import warnings

import gi
gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

from marks import APPLE

W, H = 1040, 720
HERE = os.path.dirname(os.path.abspath(__file__))
INTER = os.path.join(HERE, "fonts", "inter.woff2")
UBUNTU = "/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf"
MONO = "'DejaVu Sans Mono',monospace"
_logo = open(os.path.join(HERE, "..", "logo.svg")).read()
LOGO = re.sub(r'(url\(#|href="#|id=")', r"\1logo-", _logo[_logo.index(">", _logo.index("<svg")) + 1:_logo.rindex("</svg>")])


def font(path, size, weight=400):
    f = ImageFont.truetype(path, size)
    f.set_variation_by_axes([weight if a["name"] == b"Weight" else a["default"] for a in f.get_variation_axes()])
    return f


def render(shapes, defs=""):
    """The shapes as a W x H picture, through librsvg."""
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}"><defs>{defs}</defs>{shapes}</svg>'
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)          # get_pixbuf: fine for a one-off render
        pb = Rsvg.Handle.new_from_data(svg.encode()).get_pixbuf()
    return Image.frombytes("RGBA", (W, H), pb.get_pixels(), "raw", "RGBA", pb.get_rowstride()).convert("RGB")


# ---------------------------------------------------------------- Linux: Ubuntu's top bar and dock
BAR, DOCK = 30, 64


def linux_desktop():
    glyphs = [("#2d2d2d", f'<text x="3.5" y="13.5" font-family="{MONO}" font-size="8" font-weight="700" fill="#8ae234">&gt;_</text>'),
              ("#1e6fd9", '<circle cx="10" cy="10" r="5.5" fill="none" stroke="#fff" stroke-width="1.4"/>'
                          '<path d="M4.5 10h11M10 4.5c3 3 3 8 0 11c-3-3-3-8 0-11" fill="none" stroke="#fff"/>'),
              ("#e8912d", '<path d="M4 5h4l1.5 1.5h6.5v7h-12z" fill="#fff" fill-opacity=".92"/>'),
              ("#6c4fd6", f'<text x="3" y="13.5" font-family="{MONO}" font-size="8.5" font-weight="700" fill="#fff">{{}}</text>'),
              ("#77767b", '<circle cx="10" cy="10" r="5" fill="none" stroke="#fff" stroke-width="1.6" stroke-dasharray="2.2 1.6"/>'
                          '<circle cx="10" cy="10" r="2" fill="#fff"/>')]
    s = [f'<rect width="{W}" height="{H}" fill="url(#linux)"/>',
         f'<rect width="{W}" height="{BAR}" fill="#0d0d0f"/>',
         '<rect x="14" y="10" width="26" height="10" rx="5" fill="#fff"/>'
         '<circle cx="49" cy="15" r="3.5" fill="#fff" fill-opacity=".55"/><circle cx="61" cy="15" r="3.5" fill="#fff" fill-opacity=".55"/>',
         f'<g transform="translate({W - 92} .6) scale(1.8)" fill="none" stroke="#f2f2f2" stroke-width="1.1" stroke-linecap="round">'
         '<path d="M0 10l3-4 3 4z" fill="#f2f2f2"/><path d="M13 6.5v3h2l2.5 2v-7l-2.5 2z" fill="#f2f2f2" stroke="none"/>'
         '<path d="M19.5 5.5a3.5 3.5 0 0 1 0 5"/><circle cx="32" cy="8.3" r="3"/><path d="M32 4.2v3"/></g>',
         f'<rect y="{BAR}" width="{DOCK}" height="{H - BAR}" fill="#161618" fill-opacity=".86"/>']
    for i, (bg, g) in enumerate(glyphs):
        s.append(f'<g transform="translate(10 {BAR + 10 + i * 54}) scale(2.2)"><rect width="20" height="20" rx="5" fill="{bg}"/>{g}</g>')
    y = BAR + 10 + len(glyphs) * 54                              # Darpan, open, with Ubuntu's orange dot
    s.append(f'<g transform="translate(10 {y}) scale({44 / 128})">{LOGO}</g><circle cx="4" cy="{y + 22}" r="2.6" fill="#e95420"/>')
    s.append("".join(f'<circle cx="{24 + k % 3 * 8}" cy="{H - 40 + k // 3 * 8}" r="2" fill="#fff" fill-opacity=".8"/>' for k in range(9)))
    im = render("".join(s), '<linearGradient id="linux" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1c0b1f"/>'
                            '<stop offset=".55" stop-color="#4f1440"/><stop offset="1" stop-color="#a8392b"/></linearGradient>')
    ImageDraw.Draw(im).text((W / 2, BAR / 2), "Sep 26  09:41", font=font(UBUNTU, 14, 600), fill="#f2f2f2", anchor="mm")
    return im


# ---------------------------------------------------------------- Mac: the menu bar and the Dock
MENU, DOCK_H = 25, 58
MENUS = {"Finder": ["File", "Edit", "View", "Go", "Window", "Help"],
         "Darpan": ["Edit", "View", "Connection", "Window", "Help"]}     # the app's real menus: no File menu


def mac_desktop(app):
    bold, regular = font(INTER, 13, 700), font(INTER, 13)
    clock = "Sat 26 Sep  9:41"
    cx = W - 16 - regular.getlength(clock)                       # where the clock starts
    icons = ["#2f8cff", "#34c759", "#ff9f0a", "#bf5af2", "#ff453a", "#64d2ff"] + (["darpan"] if app == "Darpan" else [])
    dw = len(icons) * 54 + 4
    dx, dy = (W - dw) / 2, H - 6 - DOCK_H
    s = [f'<rect width="{W}" height="{H}" fill="url(#wall)"/><rect width="{W}" height="{H}" fill="url(#glow)"/>',
         f'<rect width="{W}" height="{MENU}" fill="#fff" fill-opacity=".16"/>',
         f'<path transform="translate(16 5.5) scale({14 / 24:.4f})" d="{APPLE}" fill="#fff"/>',
         f'<g fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round" transform="translate({cx - 58:.1f} 0)">'
         '<path d="M-6.4 9.5a9 9 0 0 1 12.8 0M-3.6 12.3a5 5 0 0 1 7.2 0"/><circle cy="15.6" r="1.3" fill="#fff" stroke="none"/></g>',
         f'<g transform="translate({cx - 38:.1f} 8)"><rect width="21" height="10" rx="3" fill="none" stroke="#fff" stroke-opacity=".9"/>'
         '<rect x="2" y="2" width="14" height="6" rx="1.5" fill="#fff"/><path d="M22.8 3.4v3.2" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/></g>',
         f'<rect x="{dx:.1f}" y="{dy}" width="{dw}" height="{DOCK_H}" rx="18" fill="#fff" fill-opacity=".2" stroke="#fff" stroke-opacity=".35"/>']
    for i, c in enumerate(icons):
        x = dx + 6 + i * 54
        if c == "darpan":
            s.append(f'<rect x="{x:.1f}" y="{dy + 6}" width="46" height="46" rx="11" fill="#1d2366"/>'
                     f'<g transform="translate({x + 4:.1f} {dy + 10}) scale({38 / 128})">{LOGO}</g>')
        else:
            s.append(f'<rect x="{x:.1f}" y="{dy + 6}" width="46" height="46" rx="11" fill="{c}"/>')
        if i == 0 or c == "darpan":                              # open: Finder always, Darpan once it runs
            s.append(f'<circle cx="{x + 23:.1f}" cy="{dy + DOCK_H - 2.5}" r="2" fill="#fff" fill-opacity=".85"/>')
    im = render("".join(s), '<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#16225c"/>'
                            '<stop offset=".45" stop-color="#43308f"/><stop offset=".78" stop-color="#a1528f"/><stop offset="1" stop-color="#e59a74"/>'
                            '</linearGradient><radialGradient id="glow" cx=".72" cy=".2" r=".6"><stop offset="0" stop-color="#fff" stop-opacity=".16"/>'
                            '<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>')
    d, x = ImageDraw.Draw(im), 46
    for i, m in enumerate([app] + MENUS[app]):
        f = bold if i == 0 else regular
        d.text((x, MENU / 2), m, font=f, fill="#fff", anchor="lm")
        x += f.getlength(m) + 21
    d.text((cx, MENU / 2), clock, font=regular, fill="#fff", anchor="lm")
    return im


# ---------------------------------------------------------------- windows and frames
def place(bg, win, area, radius, blur, dy, opacity):
    """bg with win centred in area (x0, y0, x1, y1), its corners round, casting a soft shadow."""
    big = Image.new("L", (win.width * 4, win.height * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, big.width - 1, big.height - 1], radius * 4, fill=255)
    win = win.convert("RGBA")
    win.putalpha(ImageChops.multiply(win.getchannel("A"), big.resize(win.size, Image.LANCZOS)))
    x = area[0] + (area[2] - area[0] - win.width) // 2
    y = area[1] + (area[3] - area[1] - win.height) // 2
    pad = 3 * blur
    shadow = Image.new("L", (win.width + 2 * pad, win.height + 2 * pad), 0)
    shadow.paste(win.getchannel("A").point(lambda a: a * opacity // 255), (pad, pad + dy))
    out = bg.copy()
    out.paste(Image.new("RGB", shadow.size), (x - pad, y - pad), shadow.filter(ImageFilter.GaussianBlur(blur)))
    out.paste(win, (x, y), win)
    return out


if __name__ == "__main__":
    shots, dest = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else HERE
    linux = linux_desktop()
    finder, darpan = mac_desktop("Finder"), mac_desktop("Darpan")
    runs = [("linux", [place(linux, Image.open(f"{shots}/linux-{i}.png"), (DOCK, BAR, W, H), 12, 14, 8, 120) for i in range(1, 5)],
             [2200, 2200, 2200, 3500], 3),                                   # the still: You're set
            ("mac", [place(finder if i == 1 else darpan, Image.open(f"{shots}/mac-{i}.png"), (0, MENU, W, H - 6 - DOCK_H), 18, 18, 14, 135)
                     for i in range(1, 6)], [2200] * 4 + [3500], 1)]        # the still: Welcome
    for name, frames, durations, still in runs:
        anim, pic = os.path.join(dest, f"onboarding-{name}.webp"), os.path.join(dest, f"onboarding-{name}-still.webp")
        frames[0].save(anim, save_all=True, append_images=frames[1:], duration=durations, loop=0, quality=92, method=6, minimize_size=True)
        frames[still].save(pic, quality=92, method=6)
        print(f"onboarding-{name}: {os.path.getsize(anim) // 1024} KB, still {os.path.getsize(pic) // 1024} KB")
