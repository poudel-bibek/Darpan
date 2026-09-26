"""Makes the disk image's window: `How to open Darpan.png` (the one-time Open Anyway steps, since
Darpan isn't notarized) and `DS_Store` (icon positions and view options; no background image, which
Finder on macOS 26 doesn't show). build.sh copies both into the DMG. To regenerate:

    python3 -m pip install pillow ds_store && python3 mac/assets/dmg/make.py
"""
import os
from PIL import Image, ImageDraw, ImageFont
from ds_store import DSStore

HERE = os.path.dirname(os.path.abspath(__file__))
GUIDE = "How to open Darpan.png"


def font(size, bold=False):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_name("Semibold" if bold else "Regular")
    return f


def guide():
    S = 2
    W, H = 720 * S, 400 * S
    s = lambda v: int(v * S)
    im = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.text((s(40), s(48)), "How to open Darpan the first time", font=font(s(26), True), fill=(28, 28, 32), anchor="lm")
    d.text((s(40), s(84)), "It’s free and open source, so it isn’t registered with Apple. macOS asks once.",
           font=font(s(15)), fill=(110, 110, 118), anchor="lm")
    steps = [
        ("Drag Darpan to Applications, then open it.", None),
        ("macOS says it can’t check Darpan. Click Done.", "Done"),
        ("Open System Settings → Privacy & Security.", None),
        ("Scroll down and click Open Anyway. That’s all.", "Open Anyway"),
    ]
    for i, (t, button) in enumerate(steps):
        cy = s(142) + i * s(62)
        d.ellipse([s(40), cy - s(15), s(70), cy + s(15)], fill=(0, 122, 255))
        d.text((s(55), cy), str(i + 1), font=font(s(16), True), fill=(255, 255, 255), anchor="mm")
        d.text((s(88), cy), t, font=font(s(17)), fill=(40, 40, 46), anchor="lm")
        if button:
            w = s(18 + 9 * len(button))
            x = W - s(40) - w
            d.rounded_rectangle([x, cy - s(16), x + w, cy + s(16)], radius=s(8), fill=(236, 236, 240),
                                outline=(204, 204, 212), width=s(1))
            d.text((x + w // 2, cy), button, font=font(s(15)), fill=(28, 28, 32), anchor="mm")
    im.save(os.path.join(HERE, GUIDE), dpi=(144, 144))


def layout():
    path = os.path.join(HERE, "DS_Store")
    if os.path.exists(path):
        os.remove(path)
    with DSStore.open(path, "w+") as d:
        d["."]["bwsp"] = {"ShowStatusBar": False, "ShowToolbar": False, "ShowTabView": False, "ShowSidebar": False,
                          "ContainerShowSidebar": False, "ShowPathbar": False, "PreviewPaneVisibility": False,
                          "WindowBounds": "{{200, 120}, {660, 420}}"}
        d["."]["icvp"] = {"viewOptionsVersion": 1, "arrangeBy": "none", "iconSize": 96.0, "textSize": 13.0,
                          "labelOnBottom": True, "showIconPreview": True, "showItemInfo": False,
                          "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0, "backgroundType": 0,
                          "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
                          "scrollPositionX": 0.0, "scrollPositionY": 0.0}
        d["."]["icvl"] = ("type", b"icnv")
        d["."]["vSrn"] = ("long", 1)
        d["Darpan.app"]["Iloc"] = (165, 125)
        d["Applications"]["Iloc"] = (495, 125)
        d[GUIDE]["Iloc"] = (330, 300)


guide()
layout()
