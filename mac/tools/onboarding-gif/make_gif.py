"""docs/onboarding-mac.gif from five window screenshots, all with sample data only.

1. the DMG window (mount dist/Darpan.dmg)
2. f2-welcome.png: a debug build with DARPAN_DEBUG_DEMO=1 DARPAN_DEBUG_WELCOME=1
3. f3-computers.png: DARPAN_DEBUG_DEMO=1 (one computer, "workstation")
4. f4-password.png: the same, then the debug commands `pick https://workstation.example.ts.net` and `typepw …`
5. f5-desktop.png: DARPAN_DEBUG_DEMO=1 connected to `FakeHost --name workstation --image desktop.png`
   (desktop.py draws that picture), with the toolbar tip showing

Dark appearance, no cursor (screencapture -x -o -l <window>). Needs Pillow. Run it where the
screenshots are: python3 make_gif.py
"""
from PIL import Image, ImageDraw, ImageFilter
W, H = 880, 560
frames = ["f1-dmg.png", "f2-welcome.png", "f3-computers.png", "f4-password.png", "f5-desktop.png"]
# the last frame: the part of the desktop around the toolbar and its tip, so the tip is readable
from PIL import Image as _I
_f5 = _I.open("f5-desktop.png"); _w, _h = _f5.size
_f5.crop((int(_w * 0.71), 0, _w, int(_h * 0.38))).save("f5-crop.png")
frames[-1] = "f5-crop.png"
def canvas():
    c = Image.new("RGB", (W, H), (22, 22, 26))
    d = ImageDraw.Draw(c)
    return c
out = []
for name in frames:
    im = Image.open(name).convert("RGBA")
    box_w, box_h = W - 60, H - 60
    s = min(box_w / im.width, box_h / im.height, 1.6)
    im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    c = canvas()
    x, y = (W - im.width) // 2, (H - im.height) // 2
    shadow = Image.new("RGBA", (im.width + 40, im.height + 40), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([20, 26, im.width + 20, im.height + 20], radius=16, fill=(0, 0, 0, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(12))
    c.paste(shadow, (x - 20, y - 20), shadow)
    c.paste(im, (x, y), im)
    # UI frames: exact colours; the last one (a gradient wallpaper): dithered, so it doesn't band
    last = name == frames[-1]
    out.append(c.quantize(colors=256, method=Image.Quantize.FASTOCTREE,
                          dither=Image.Dither.FLOYDSTEINBERG if last else Image.Dither.NONE))
durations = [2200] * (len(out) - 1) + [3500]
out[0].save("onboarding-mac.gif", save_all=True, append_images=out[1:], duration=durations, loop=0, optimize=True, disposal=1)
import os; print(os.path.getsize("onboarding-mac.gif") // 1024, "KB")
