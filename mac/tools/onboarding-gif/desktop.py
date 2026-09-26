"""desktop.png: a made-up Linux desktop (sample data only) for FakeHost --image, used for the README's
onboarding animation. Needs Pillow."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
W, H = 1920, 1080
def f(size, bold=False, mono=False):
    p = "/System/Library/Fonts/SFNSMono.ttf" if mono else "/System/Library/Fonts/SFNS.ttf"
    ft = ImageFont.truetype(p, size)
    try: ft.set_variation_by_name("Semibold" if bold else "Regular")
    except Exception: pass
    return ft
# wallpaper: a deep aubergine to warm orange diagonal glow
im = Image.new("RGB", (W, H))
px = im.load()
for y in range(H):
    for x in range(0, W):
        t = (x / W * 0.6 + y / H * 0.4)
        r = int(44 + (233 - 44) * t ** 1.8)
        g = int(0 + (84 - 0) * t ** 2.2)
        b = int(30 + (32 - 30) * t)
        px[x, y] = (r, g, b)
im = im.filter(ImageFilter.GaussianBlur(2))
d = ImageDraw.Draw(im, "RGBA")
# top bar
d.rectangle([0, 0, W, 32], fill=(12, 12, 14, 255))
d.text((18, 16), "Activities", font=f(15, True), fill=(235, 235, 235), anchor="lm")
d.text((W // 2, 16), "Sat 26 Sep  10:42", font=f(15, True), fill=(235, 235, 235), anchor="mm")
for i, c in enumerate([(235, 235, 235)] * 3):
    x = W - 110 + i * 30
    d.rounded_rectangle([x, 10, x + 16, 22], radius=3, outline=c, width=2)
# dock on the left
d.rounded_rectangle([8, 48, 76, 560], radius=18, fill=(20, 20, 24, 170))
colors = [(233, 84, 32), (52, 120, 246), (76, 175, 80), (156, 39, 176), (255, 193, 7), (96, 125, 139)]
for i, c in enumerate(colors):
    y = 64 + i * 80
    d.rounded_rectangle([20, y, 64, y + 44], radius=11, fill=c + (255,))
# a terminal window
x0, y0, x1, y1 = 300, 150, 1320, 760
d.rounded_rectangle([x0 + 6, y0 + 10, x1 + 6, y1 + 14], radius=14, fill=(0, 0, 0, 90))
d.rounded_rectangle([x0, y0, x1, y1], radius=12, fill=(30, 30, 34, 255))
d.rounded_rectangle([x0, y0, x1, y0 + 44], radius=12, fill=(48, 48, 52, 255))
d.rectangle([x0, y0 + 30, x1, y0 + 44], fill=(48, 48, 52, 255))
d.text(((x0 + x1) // 2, y0 + 22), "user@workstation: ~", font=f(15, True), fill=(220, 220, 220), anchor="mm")
for i, c in enumerate([(237, 106, 94), (245, 191, 79), (98, 197, 84)]):
    cx = x1 - 30 - i * 26
    d.ellipse([cx - 7, y0 + 15, cx + 7, y0 + 29], fill=(90, 90, 96))
lines = [
    ("user@workstation:~$ ", "python train.py --epochs 40", (138, 226, 52)),
    ("", "loading dataset … 128,000 images", None),
    ("", "epoch 11/40  loss 0.4381  acc 90.8%", None),
    ("", "epoch 12/40  loss 0.4172  acc 91.3%", None),
    ("", "epoch 13/40  loss 0.3996  acc 91.9%", None),
    ("", "epoch 14/40  loss 0.3850  acc 92.4%   ██████████████░░░░░░░░░░  35%", None),
]
y = y0 + 70
for p, t, pc in lines:
    x = x0 + 24
    if p:
        d.text((x, y), p, font=f(18, mono=True), fill=pc, anchor="lm")
        x += int(d.textlength(p, font=f(18, mono=True)))
    d.text((x, y), t, font=f(18, mono=True), fill=(225, 225, 225), anchor="lm")
    y += 34
d.rectangle([x0 + 24, y - 12, x0 + 34, y + 12], fill=(225, 225, 225))
im.save("desktop.png")
