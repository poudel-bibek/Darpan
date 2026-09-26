#!/usr/bin/env python3
"""Generates docs/demo.svg, a looping CSS-animated illustration of Darpan in use: connect from the
Mac, start a training run in a Linux terminal, open the toolbar tab, click Full screen, and watch
the run finish full screen. Pure SVG + CSS (no scripts or external resources), so it animates in a
GitHub README. Usage: python3 docs/demo.py docs/demo.svg"""
import sys

T = 16.0                                   # loop length, seconds
UI = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
MONO = "ui-monospace,'SF Mono',Menlo,Consolas,'DejaVu Sans Mono',monospace"
css, body = [], []


def pct(t):
    return f"{max(0.0, min(100.0, 100 * t / T)):.3f}%"


def anim(name, frames, timing="linear", extra=""):
    """frames: [(t, 'css declarations')]; emits @keyframes and a class that runs them."""
    ks = "".join(f"{pct(t)}{{{p}}}" for t, p in frames)
    css.append(f"@keyframes {name}{{{ks}}}.{name}{{animation:{name} {T}s {timing} infinite;{extra}}}")


def show(name, on, off, fade=0.15):
    """Visible from `on` to `off`, fading in/out over `fade` seconds."""
    f = [(0, "opacity:0")]
    if on <= 0:
        f = [(0, "opacity:1")]
    else:
        f += [(on, "opacity:0"), (on + fade, "opacity:1")]
    if off < T:
        f += [(off, "opacity:1"), (off + fade, "opacity:0"), (T, "opacity:0")]
    else:
        f += [(T, "opacity:1")]
    anim(name, f)


# ---------------------------------------------------------------- timeline (seconds)
CW_IN, CLICK, CW_OUT = 0.0, 1.55, 2.6          # connect window
VW_IN, VW_OUT = 2.75, 15.1                      # viewer window
TYPE0, TYPE_DT = 3.95, 0.065                    # typing
CMD = "python train.py --epochs 3"
ENTER = TYPE0 + len(CMD) * TYPE_DT + 0.3
L2, L3, L4 = ENTER + 0.45, ENTER + 1.05, ENTER + 1.65
BAR_END = 13.0                                  # epoch 3 reaches 100 %
L5 = BAR_END + 0.35
PILL_HOVER, BAR_OPEN = 8.6, 8.85                # the tab expands into the toolbar
FS_HOVER, FS_CLICK = 9.4, 10.15                 # pointer on Full screen, then the click
BAR_CLOSE, FS_T0, FS_T1 = 10.25, 10.3, 10.95    # toolbar tucks away; the window grows to full screen

# ---------------------------------------------------------------- geometry
W, H = 960, 600
CX, CY = 330, 104                               # connect window origin (300×408)
VX, VY, VW_, VH = 70, 60, 820, 489              # viewer window (28 px title + 461 px video)
DX, DY = VX, VY + 28                            # Linux desktop origin (820×461)
TX, TY = DX + 110, DY + 44                      # terminal origin (580×324)
FS, LH = 10.5, 16                               # terminal font size, line height
CHW = FS * 0.6                                  # monospace advance
PROMPT = "user@workstation:~/project$ "
CMDX = TX + 12 + len(PROMPT) * CHW
BTN = (CX + 150, CY + 354)                      # Connect button centre
PILL = (DX + 600, DY + 7)                       # tab dragged right of the clock; the open bar stays clear of it

# ---------------------------------------------------------------- defs
defs = f"""<defs>
<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#16225c"/><stop offset=".45" stop-color="#43308f"/><stop offset=".78" stop-color="#a1528f"/><stop offset="1" stop-color="#e59a74"/></linearGradient>
<radialGradient id="glow" cx=".72" cy=".2" r=".6"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<linearGradient id="linux" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1c0b1f"/><stop offset=".55" stop-color="#4f1440"/><stop offset="1" stop-color="#a8392b"/></linearGradient>
<filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity=".38"/></filter>
<filter id="soft" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="2" stdDeviation="2.5" flood-color="#000" flood-opacity=".35"/></filter>
<clipPath id="screen"><rect width="{W}" height="{H}" rx="16"/></clipPath>
<clipPath id="video"><rect x="{DX}" y="{DY}" width="820" height="461"/></clipPath>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FAD57A"/><stop offset="1" stop-color="#C98A1E"/></linearGradient>
<linearGradient id="deep" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#E4A845"/><stop offset="1" stop-color="#9C6610"/></linearGradient>
<radialGradient id="glass" cx=".36" cy=".3" r=".85"><stop offset="0" stop-color="#3E66CC"/><stop offset="1" stop-color="#0C1533"/></radialGradient>
<path id="petal" d="M0-30C17-38 12-54 0-62C-12-54-17-38 0-30Z"/>
<path id="bud" d="M0-30C13-37 10-49 0-55C-10-49-13-37 0-30Z"/>
<g id="logo" stroke="#8E5B0E" stroke-linejoin="round">
<g fill="url(#gold)" stroke-width="1.2">{"".join(f'<use href="#petal" transform="rotate({a})"/>' for a in range(0, 360, 45))}</g>
<g fill="url(#deep)" stroke-width="1">{"".join(f'<use href="#bud" transform="rotate({a + 22.5})"/>' for a in range(0, 360, 45))}</g>
<circle r="38" fill="url(#gold)" stroke-width="1.5"/><circle r="34.5" fill="none" stroke="#B57B19"/>
<circle r="31" fill="url(#glass)" stroke="#7A4C0B" stroke-width="1.5"/>
<path d="M-23-6A23 23 0 0 1-6-23" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="3.5" stroke-linecap="round"/>
<path d="M-9-17V11L-2.5 4.5 2 14.5 6.5 12.5 2 2.5H11Z" fill="#fff" stroke="#0C1533" stroke-width="2.2"/>
</g>
<path id="arrow" d="M0 0V15.5L3.6 12.1 6.1 17.9 8.6 16.8 6.1 11.1H11.2Z" fill="#000" stroke="#fff" stroke-width="1.1" stroke-linejoin="round"/>
</defs>"""


def traffic(x, y):
    return "".join(f'<circle cx="{x + i * 20}" cy="{y}" r="6" fill="{c}" stroke="{s}" stroke-width=".6"/>'
                   for i, (c, s) in enumerate([("#ff5f57", "#e0443e"), ("#febc2e", "#dea123"), ("#28c840", "#1aab29")]))


# ---------------------------------------------------------------- Mac desktop
body.append(f'<rect width="{W}" height="{H}" fill="url(#wall)"/><rect width="{W}" height="{H}" fill="url(#glow)"/>')
# the app's real menus (there's no File menu); x from typical 12 px system-font widths, ~18 px apart
items = "".join(f'<text x="{x}" y="16">{m}</text>' for m, x in
                [("Edit", 84), ("View", 124), ("Connection", 169), ("Window", 249), ("Help", 313)])
body.append(f'<rect width="{W}" height="24" fill="#fff" fill-opacity=".16"/>'
            f'<g font-family="{UI}" font-size="12" fill="#fff"><text x="20" y="16" font-weight="700">Darpan</text>{items}'
            f'<text x="{W - 18}" y="16" text-anchor="end">Sat 26 Sep  9:41</text></g>'
            f'<g fill="none" stroke="#fff" stroke-width="1.4" stroke-linecap="round">'
            f'<path d="M796.3 9.3a8 8 0 0 1 11.4 0M798.8 11.8a4.5 4.5 0 0 1 6.4 0"/><circle cx="802" cy="14.8" r="1.2" fill="#fff" stroke="none"/>'
            f'<rect x="816" y="8" width="17" height="8" rx="2.5"/><rect x="818" y="10" width="11" height="4" rx="1" fill="#fff" stroke="none"/>'
            f'<path d="M834.6 10.5v3" stroke-width="1.6"/></g>')

# ---------------------------------------------------------------- connect window
cw = [f'<rect width="300" height="408" rx="12" fill="#fff" stroke="#000" stroke-opacity=".1"/>', traffic(18, 16),
      '<use href="#logo" transform="translate(150 74) scale(.47)"/>',
      f'<g font-family="{UI}" text-anchor="middle"><text x="150" y="128" font-size="18" font-weight="600" fill="#1d1d1f">Darpan</text>'
      '<text x="150" y="145" font-size="11" fill="#86868b">Your Linux desktop, on this Mac</text></g>',
      f'<g font-family="{UI}" font-size="10" fill="#86868b"><text x="24" y="175">Private network</text>'
      '<text x="24" y="228">Address</text><text x="24" y="276">Password</text></g>',
      '<rect x="164" y="163" width="112" height="17" rx="5" fill="#e8e8ed"/>'
      '<rect x="165.5" y="164.5" width="52" height="14" rx="4" fill="#fff" filter="url(#soft)"/>',
      f'<g font-family="{UI}" font-size="9.5" fill="#1d1d1f" text-anchor="middle"><text x="191.5" y="175">Built-in</text><text x="247" y="175">This Mac’s</text></g>',
      '<rect x="24" y="186" width="252" height="24" rx="6" fill="#f2f2f5"/><circle cx="36" cy="198" r="3.6" fill="#34c759"/>',
      f'<text x="46" y="201.5" font-family="{UI}" font-size="10.5" fill="#1d1d1f">Connected as you@example.com</text>',
      '<rect x="24" y="233" width="226" height="22" rx="5" fill="#fff" stroke="#c7c7cc"/>',
      f'<text x="31" y="248" font-family="{UI}" font-size="11" fill="#1d1d1f">workstation.example.ts.net</text>',
      '<g fill="none" stroke="#86868b" stroke-width="1.2" stroke-linecap="round" transform="translate(-3 0)"><path d="M259.5 244a6.5 6.5 0 1 0 2-4.7"/><path d="M259 237v3.5h3.5"/><path d="M266 240.5v3.8l2.4 1.6"/></g>',
      '<rect x="24" y="281" width="252" height="22" rx="5" fill="#fff" stroke="#c7c7cc"/>',
      f'<text x="31" y="296.5" font-family="{UI}" font-size="11" letter-spacing="1.5" fill="#1d1d1f">••••••••••••••</text>',
      '<rect x="24" y="314" width="12" height="12" rx="3" fill="#0a84ff"/><path d="M27 320l2.3 2.4 4-5" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>',
      f'<text x="43" y="324" font-family="{UI}" font-size="10.5" fill="#1d1d1f">Remember on this Mac</text>',
      '<rect class="btn" x="24" y="340" width="252" height="28" rx="7" fill="#0a84ff"/>',
      f'<text class="lbl1" x="150" y="358.5" font-family="{UI}" font-size="12" font-weight="600" fill="#fff" text-anchor="middle">Connect</text>',
      f'<g class="lbl2"><text x="157" y="358.5" font-family="{UI}" font-size="12" font-weight="600" fill="#fff" text-anchor="middle">Cancel</text>'
      '<g transform="translate(125 354)"><circle class="spin" r="5" fill="none" stroke="#fff" stroke-opacity=".9" stroke-width="1.6" stroke-dasharray="20 12" stroke-linecap="round"/></g></g>',
      f'<text class="msg" x="150" y="390" font-family="{UI}" font-size="10" fill="#86868b" text-anchor="middle">Connecting to workstation…</text>']
body.append(f'<g class="cw"><g transform="translate({CX} {CY})" filter="url(#shadow)">{"".join(cw)}</g></g>')
anim("cw", [(0, "opacity:0;transform:scale(.97)"), (0.35, "opacity:1;transform:scale(1)"),
            (CW_OUT, "opacity:1;transform:scale(1)"), (CW_OUT + 0.35, "opacity:0;transform:scale(.94)"),
            (T, "opacity:0;transform:scale(.94)")], extra="transform-origin:480px 308px")
anim("btn", [(0, "fill:#0a84ff"), (CLICK, "fill:#0a84ff"), (CLICK + 0.04, "fill:#0062cc"),
             (CLICK + 0.2, "fill:#0062cc"), (CLICK + 0.3, "fill:#0a84ff"), (T, "fill:#0a84ff")])
show("lbl1", 0, CLICK + 0.2, 0.001)
show("lbl2", CLICK + 0.2, T, 0.001)
show("msg", CLICK + 0.25, T, 0.1)
css.append(f"@keyframes spin{{to{{transform:rotate(360deg)}}}}.spin{{animation:spin .8s linear infinite}}")

# ---------------------------------------------------------------- viewer window with the Linux desktop
v = [f'<rect x="{VX}" y="{VY}" width="{VW_}" height="{VH}" rx="11" fill="#1a1a1a" stroke="#000" stroke-opacity=".25"/>',
     f'<path d="M{VX} {VY + 28}V{VY + 11}a11 11 0 0 1 11-11H{VX + VW_ - 11}a11 11 0 0 1 11 11V{VY + 28}Z" fill="#ececec"/>',
     f'<line x1="{VX}" y1="{VY + 28}" x2="{VX + VW_}" y2="{VY + 28}" stroke="#000" stroke-opacity=".15"/>',
     traffic(VX + 18, VY + 14),
     f'<text x="{VX + VW_ / 2}" y="{VY + 18.5}" font-family="{UI}" font-size="12" font-weight="600" fill="#3c3c43" text-anchor="middle">workstation</text>']
d = [f'<rect x="{DX}" y="{DY}" width="820" height="461" fill="url(#linux)"/>',
     f'<rect x="{DX}" y="{DY}" width="820" height="16" fill="#0d0d0f"/>',
     f'<rect x="{DX + 9}" y="{DY + 5}" width="13" height="6" rx="3" fill="#fff"/><circle cx="{DX + 27}" cy="{DY + 8}" r="2" fill="#fff" fill-opacity=".55"/><circle cx="{DX + 33}" cy="{DY + 8}" r="2" fill="#fff" fill-opacity=".55"/>',
     f'<text x="{DX + 410}" y="{DY + 11.5}" font-family="{UI}" font-size="8.5" font-weight="600" fill="#f2f2f2" text-anchor="middle">Sep 26  09:41</text>',
     f'<g fill="none" stroke="#f2f2f2" stroke-width="1.1" stroke-linecap="round"><path d="M{DX + 770} {DY + 10}l3-4 3 4z" fill="#f2f2f2"/>'
     f'<path d="M{DX + 783} {DY + 6.5}v3h2l2.5 2v-7l-2.5 2z" fill="#f2f2f2" stroke="none"/><path d="M{DX + 789.5} {DY + 5.5}a3.5 3.5 0 0 1 0 5"/>'
     f'<circle cx="{DX + 802}" cy="{DY + 8.3}" r="3"/><path d="M{DX + 802} {DY + 4.2}v3"/></g>',
     f'<rect x="{DX}" y="{DY + 16}" width="32" height="445" fill="#161618" fill-opacity=".86"/>']
icons = [("#2d2d2d", '<text x="{x}" y="{y}" font-family="' + MONO + '" font-size="8" font-weight="700" fill="#8ae234">&gt;_</text>'),
         ("#1e6fd9", '<circle cx="{cx}" cy="{cy}" r="5.5" fill="none" stroke="#fff" stroke-width="1.4"/><path d="M{cx0} {cy}h11M{cx} {cy0}c3 3 3 8 0 11c-3-3-3-8 0-11" fill="none" stroke="#fff" stroke-width="1"/>'),
         ("#e8912d", '<path d="M{x0} {y1}h4l1.5 1.5h6.5v7h-12z" fill="#fff" fill-opacity=".92"/>'),
         ("#6c4fd6", '<text x="{x2}" y="{y}" font-family="' + MONO + '" font-size="8.5" font-weight="700" fill="#fff">{{}}</text>'),
         ("#77767b", '<circle cx="{cx}" cy="{cy}" r="5" fill="none" stroke="#fff" stroke-width="1.6" stroke-dasharray="2.2 1.6"/><circle cx="{cx}" cy="{cy}" r="2" fill="#fff"/>')]
for i, (bg, glyph) in enumerate(icons):
    x, y = DX + 6, DY + 26 + i * 30
    d.append(f'<rect x="{x}" y="{y}" width="20" height="20" rx="5" fill="{bg}"/>')
    d.append(glyph.format(x=x + 3.5, y=y + 13.5, x2=x + 3, cx=x + 10, cy=y + 10, cx0=x + 4.5, cy0=y + 4.5, x0=x + 4, y1=y + 5))
d.append(f'<circle cx="{DX + 2.5}" cy="{DY + 36}" r="1.6" fill="#e95420"/>')
d.append("".join(f'<circle cx="{DX + 11 + (k % 3) * 5}" cy="{DY + 440 + (k // 3) * 5}" r="1.2" fill="#fff" fill-opacity=".8"/>' for k in range(9)))

# terminal window
term = [f'<rect x="{TX}" y="{TY}" width="580" height="324" rx="9" fill="#1e1b26" filter="url(#shadow)"/>',
        f'<path d="M{TX} {TY + 24}V{TY + 9}a9 9 0 0 1 9-9H{TX + 571}a9 9 0 0 1 9 9V{TY + 24}Z" fill="#303030"/>',
        f'<text x="{TX + 290}" y="{TY + 15.5}" font-family="{UI}" font-size="9" font-weight="600" fill="#e8e8e8" text-anchor="middle">user@workstation: ~/project</text>']
for k, g in enumerate(["M-2.5 0h5", "M-2.3-2.3h4.6v4.6h-4.6z", "M-2.2-2.2l4.4 4.4M2.2-2.2l-4.4 4.4"]):
    bx = TX + 536 + k * 16
    term.append(f'<circle cx="{bx}" cy="{TY + 12}" r="6" fill="#474747"/><path transform="translate({bx} {TY + 12})" d="{g}" fill="none" stroke="#e8e8e8" stroke-width="1" stroke-linecap="round"/>')
y1 = TY + 44
term.append(f'<text y="{y1}" font-family="{MONO}" font-size="{FS}" font-weight="700"><tspan x="{TX + 12}" fill="#8ae234">user@workstation</tspan>'
            f'<tspan fill="#e6e6e6">:</tspan><tspan fill="#729fcf">~/project</tspan><tspan fill="#e6e6e6">$</tspan></text>')
for i, ch in enumerate(CMD):
    if ch == " ":
        continue
    t = TYPE0 + i * TYPE_DT
    name = f"k{i}"
    term.append(f'<text class="{name}" x="{CMDX + i * CHW:.1f}" y="{y1}" font-family="{MONO}" font-size="{FS}" fill="#e6e6e6">{ch}</text>')
    anim(name, [(0, "opacity:0"), (t, "opacity:0"), (t + 0.001, "opacity:1"), (T, "opacity:1")])
# cursor: blinks while idle, follows typing, hidden after Enter
term.append(f'<g class="cmov"><rect class="cblink" x="{CMDX:.1f}" y="{y1 - 9.5}" width="{CHW:.1f}" height="12" fill="#e6e6e6"/></g>')
anim("cmov", [(0, "transform:translateX(0)")] +
     [(TYPE0 + i * TYPE_DT, f"transform:translateX({(i + 1) * CHW:.1f}px)") for i in range(len(CMD))] + [(T, f"transform:translateX({len(CMD) * CHW:.1f}px)")],
     timing="steps(1,end)")
blink = [(0, "opacity:0"), (VW_IN + 0.3, "opacity:0")]
t = VW_IN + 0.3
on = True
while t < TYPE0 - 0.05:
    blink.append((t, f"opacity:{1 if on else 0}"))
    t += 0.45
    on = not on
blink += [(TYPE0 - 0.05, "opacity:1"), (ENTER, "opacity:1"), (ENTER + 0.001, "opacity:0"), (T, "opacity:0")]
anim("cblink", blink, timing="steps(1,end)")

# training output
BX = TX + 12 + len("epoch 1/3  ") * CHW
BW = 20 * CHW


def epoch_line(n, y, cls, pcts=None, done=True, loss="", acc=""):
    s = [f'<g class="{cls}"><text x="{TX + 12}" y="{y}" font-family="{MONO}" font-size="{FS}" fill="#e6e6e6">epoch {n}/3</text>',
         f'<rect x="{BX:.1f}" y="{y - 6.5}" width="{BW:.1f}" height="5" rx="2.5" fill="#3b3645"/>']
    color = "#a3d977" if done else "#7fd1ff"
    if done:
        s.append(f'<rect x="{BX:.1f}" y="{y - 6.5}" width="{BW:.1f}" height="5" rx="2.5" fill="{color}"/>')
        s.append(f'<text x="{BX + BW + 2 * CHW:.1f}" y="{y}" font-family="{MONO}" font-size="{FS}" fill="#e6e6e6" xml:space="preserve">100%  loss {loss}  acc {acc}</text>')
    else:
        s.append(f'<rect class="grow" x="{BX:.1f}" y="{y - 6.5}" width="{BW:.1f}" height="5" rx="2.5" fill="{color}"/>')
        s.append(f'<rect class="fin" x="{BX:.1f}" y="{y - 6.5}" width="{BW:.1f}" height="5" rx="2.5" fill="#a3d977"/>')
        for j, (p, l, a) in enumerate(pcts):
            s.append(f'<text class="p{j}" x="{BX + BW + 2 * CHW:.1f}" y="{y}" font-family="{MONO}" font-size="{FS}" fill="#e6e6e6" xml:space="preserve">{p:>4}  loss {l}  acc {a}</text>')
    s.append("</g>")
    return "".join(s)


term.append(epoch_line(1, y1 + LH, "o2", loss="0.842", acc="71.2%"))
term.append(epoch_line(2, y1 + 2 * LH, "o3", loss="0.513", acc="83.9%"))
steps = [("8%", "0.497", "84.1%"), ("27%", "0.463", "85.0%"), ("46%", "0.438", "86.2%"),
         ("64%", "0.419", "86.9%"), ("83%", "0.405", "87.4%"), ("100%", "0.398", "87.8%")]
term.append(epoch_line(3, y1 + 3 * LH, "o4", pcts=steps, done=False))
term.append(f'<text class="o5" x="{TX + 12}" y="{y1 + 4 * LH}" font-family="{MONO}" font-size="{FS}" fill="#a3d977">✓ saved runs/exp1/model.pt</text>')
show("o2", L2, T, 0.001)
show("o3", L3, T, 0.001)
show("o4", L4, T, 0.001)
show("o5", L5, T, 0.001)
show("fin", BAR_END + 0.05, T, 0.2)
ts = [L4 + (BAR_END - L4) * k / (len(steps) - 1) for k in range(len(steps))]
for j in range(len(steps)):
    show(f"p{j}", ts[j], ts[j + 1] if j + 1 < len(steps) else T, 0.001)
anim("grow", [(0, "transform:scaleX(.02)"), (L4, "transform:scaleX(.02)")] +
     [(t, f"transform:scaleX({float(p.rstrip('%')) / 100:.2f})") for t, (p, _, _) in zip(ts, steps)] + [(T, "transform:scaleX(1)")],
     extra=f"transform-origin:{BX:.1f}px 0")
d.append("".join(term))

# toolbar: the collapsed tab and the expanded bar
px, py = PILL
d.append(f'<g class="pill"><path d="M{px - 23} {py - 7}h46v4a10 10 0 0 1-10 10h-26a10 10 0 0 1-10-10z" fill="#121418" fill-opacity=".62" stroke="#fff" stroke-opacity=".1"/>'
         f'<circle cx="{px - 13}" cy="{py - 0.5}" r="3" fill="#3ccf7a"/><rect x="{px - 5}" y="{py - 1.5}" width="16" height="2" rx="1" fill="#fff" fill-opacity=".45"/></g>')
bw, bh = 262, 30
bx0 = px - bw / 2
bar = [f'<path d="M{bx0} {py - 7}h{bw}v{bh - 12}a12 12 0 0 1-12 12h-{bw - 24}a12 12 0 0 1-12-12z" fill="#1c1e23" fill-opacity=".94" stroke="#fff" stroke-opacity=".08"/>',
       f'<circle cx="{bx0 + 12}" cy="{py + 8}" r="3" fill="#3ccf7a"/>']
glyphs = ["M-4.5-1.5v-3h3M4.5 1.5v3h-3M-4.5-4.5l3.5 3.5M4.5 4.5l-3.5-3.5",
          "M-5.5-4h11v7h-11zM-2 5.5h4M0 3v2.5",
          "M-6-3.5h12v7h-12zM-3.5-1h.1M-1-1h.1M1.5-1h.1M4-1h.1M-2.5 1.5h5",
          "M-3.5-3h7v8h-7zM-1.5-4.5h3v2.5h-3z",
          "M-4-1v5.5h8V-1M0 2V-5M-2.5-2.5L0-5l2.5 2.5",
          "M-4 4V0M0 4V-4M4 4V-1.5",
          "M-2.9-3.7a4.6 4.6 0 1 0 5.8 0M0-5v4.2"]
gx = bx0 + 30
for k, g in enumerate(glyphs):
    if k == 6:                                   # the app's only separator: before Disconnect
        bar.append(f'<line x1="{gx - 4}" y1="{py + 2}" x2="{gx - 4}" y2="{py + 14}" stroke="#fff" stroke-opacity=".18"/>')
        gx += 6
    hl = ' class="hov"' if k == 0 else ""
    bar.append(f'<rect{hl} x="{gx - 1}" y="{py - 2}" width="30" height="20" rx="5" fill="#fff" fill-opacity="{".16" if k == 0 else "0"}"/>'
               f'<path transform="translate({gx + 14} {py + 8})" d="{g}" fill="none" stroke="{"#ff5f57" if k == 6 else "#fff"}" '
               f'stroke-opacity="{1 if k == 6 else .88}" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>')
    if k == 0:
        hover_x = gx + 14                        # the Full screen button
    gx += 31
bar.append(f'<g class="tip"><rect x="{hover_x - 54}" y="{py + 27}" width="108" height="17" rx="4" fill="#f5f5f7" stroke="#000" stroke-opacity=".15" filter="url(#soft)"/>'
           f'<text x="{hover_x}" y="{py + 38.5}" font-family="{UI}" font-size="9.5" fill="#1d1d1f" text-anchor="middle">Full screen (⌃⌥⌘F)</text></g>')
d.append(f'<g class="bar">{"".join(bar)}</g>')
anim("pill", [(0, "opacity:1"), (BAR_OPEN, "opacity:1"), (BAR_OPEN + 0.12, "opacity:0"), (BAR_CLOSE + 0.1, "opacity:0"), (BAR_CLOSE + 0.3, "opacity:1"), (T, "opacity:1")])
anim("bar", [(0, "opacity:0;transform:scaleY(.4)"), (BAR_OPEN, "opacity:0;transform:scaleY(.4)"),
             (BAR_OPEN + 0.18, "opacity:1;transform:scaleY(1)"), (BAR_CLOSE, "opacity:1;transform:scaleY(1)"),
             (BAR_CLOSE + 0.18, "opacity:0;transform:scaleY(.4)"), (T, "opacity:0;transform:scaleY(.4)")],
     extra=f"transform-origin:{px}px {py - 7}px")
show("hov", FS_HOVER + 0.05, FS_CLICK + 0.1, 0.08)
show("tip", FS_HOVER + 0.2, FS_CLICK, 0.12)

# full screen: the video grows to the whole screen (16:9, letterboxed), the chrome and the Mac desktop go
FS_S = W / 820
FS_TX, FS_TY = -FS_S * DX, (H - 461 * FS_S) / 2 - FS_S * DY
body.append(f'<rect class="fsbg" width="{W}" height="{H}" fill="#000"/>')
body.append(f'<g class="vw"><g filter="url(#shadow)"><g class="chrome">{"".join(v)}</g>'
            f'<g class="fs"><g clip-path="url(#video)">{"".join(d)}</g></g></g></g>')
anim("fsbg", [(0, "opacity:0"), (FS_T0, "opacity:0"), (FS_T1, "opacity:1"), (VW_OUT, "opacity:1"), (VW_OUT + 0.5, "opacity:0"), (T, "opacity:0")])
anim("chrome", [(0, "opacity:1"), (FS_T0, "opacity:1"), (FS_T0 + 0.35, "opacity:0"), (T, "opacity:0")])
anim("fs", [(0, "transform:translate(0,0) scale(1)"), (FS_T0, "transform:translate(0,0) scale(1);animation-timing-function:cubic-bezier(.4,0,.2,1)"),
            (FS_T1, f"transform:translate({FS_TX:.2f}px,{FS_TY:.2f}px) scale({FS_S:.5f})"),
            (T, f"transform:translate({FS_TX:.2f}px,{FS_TY:.2f}px) scale({FS_S:.5f})")], extra="transform-origin:0 0")
anim("vw", [(0, "opacity:0;transform:scale(.96)"), (VW_IN, "opacity:0;transform:scale(.96)"),
            (VW_IN + 0.4, "opacity:1;transform:scale(1)"), (VW_OUT, "opacity:1;transform:scale(1)"),
            (VW_OUT + 0.5, "opacity:0;transform:scale(.98)"), (T, "opacity:0;transform:scale(.98)")],
     extra="transform-origin:480px 304px")

# ---------------------------------------------------------------- pointer and clicks
term_click = (TX + 330, TY + 190)
pts = [(0, (740, 540)), (0.35, (740, 540)), (1.35, BTN), (2.9, BTN), (3.5, term_click), (PILL_HOVER - 0.6, term_click),
       (PILL_HOVER, (px, py + 3)), (BAR_OPEN + 0.25, (px, py + 3)), (FS_HOVER, (hover_x + 2, py + 11)),
       (FS_CLICK + 0.15, (hover_x + 2, py + 11)), (FS_T1 + 0.2, (720, 470)), (VW_OUT, (720, 470)),
       (T, (740, 540))]
anim("ptr", [(t, f"transform:translate({x}px,{y}px);animation-timing-function:cubic-bezier(.45,0,.25,1)") for t, (x, y) in pts])
body.append('<g class="ptr"><use href="#arrow"/></g>')
for name, (x, y), t in [("r1", BTN, CLICK), ("r2", term_click, 3.62), ("r3", (hover_x + 2, py + 11), FS_CLICK)]:
    body.append(f'<g transform="translate({x} {y})"><circle class="{name}" r="14" fill="#fff" fill-opacity=".35" stroke="#fff" stroke-opacity=".8"/></g>')
    anim(name, [(0, "opacity:0;transform:scale(.3)"), (t, "opacity:0;transform:scale(.3)"), (t + 0.02, "opacity:1;transform:scale(.4)"),
                (t + 0.45, "opacity:0;transform:scale(1.25)"), (T, "opacity:0;transform:scale(1.25)")])

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
       f'aria-label="Darpan on a Mac: connect, start a training run in a Linux terminal, switch to full screen">'
       f'<title>Darpan: your Linux desktop on your Mac</title>'
       f'<style>{"".join(css)}@media (prefers-reduced-motion:reduce){{*{{animation-play-state:paused!important}}}}</style>'
       f'{defs}<g clip-path="url(#screen)">{"".join(body)}</g></svg>')
open(sys.argv[1], "w").write(svg)
print(f"{sys.argv[1]}: {len(svg.encode()) / 1024:.1f} KB")
