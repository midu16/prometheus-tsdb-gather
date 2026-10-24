#!/usr/bin/env python3
"""Render an evidence transcript (.log) as a terminal-styled PNG.

Usage: render_term.py <input.log> <output.png> [title]

Colors:
  $ prompt        cyan -> white
  FATAL / Killed  red
  WARN            yellow
  OK / allowed    green
  default text    light gray on near-black
"""
import sys, re
from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/source-foundry-hack-fonts/Hack-Regular.ttf"
FONTSIZE = 20
BG = (18, 18, 22)
FG = (210, 210, 214)
PROMPT = (86, 156, 214)   # cyan-blue
CMD = (230, 230, 232)
RED = (240, 90, 90)
YEL = (238, 198, 80)
GRN = (110, 200, 120)
TITLEBAR = (30, 30, 36)
TITLEFG = (150, 150, 156)

def pick_color(line):
    if line.startswith("$ "):
        return None  # handled by splitting prompt/output
    if "FATAL" in line:
        return RED
    if "Killed" in line or "terminating" in line:
        return RED
    if "WARN" in line:
        return YEL
    if re.search(r"\bOK\b", line) or " decision=allow" in line or " - allowed" in line or "status=allow" in line:
        return GRN
    if "decision=deny" in line:
        return RED
    if "rc=0" in line or "framework rc=0" in line:
        return GRN
    if "ratio=" in line:
        return GRN
    if "No such file" in line or "failed" in line.lower():
        return RED
    return None

def main():
    inp, outp = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else inp
    lines = []
    with open(inp) as f:
        for raw in f.read().rstrip("\n").split("\n"):
            lines.append(raw.rstrip())

    font = ImageFont.truetype(FONT, FONTSIZE)
    mono_w = font.getlength("M")
    # Determine width in chars, min 34
    maxch = max([len(l) for l in lines] + [34])
    # wrap long lines at maxch
    wrapped = []
    for l in lines:
        while len(l) > maxch:
            wrapped.append(l[:maxch])
            l = l[maxch:]
        wrapped.append(l)
    lines = wrapped

    padx, pady = 28, 24
    lh = int(FONTSIZE * 1.5)
    W = int(maxch * mono_w) + padx * 2 + 24
    H = len(lines) * lh + pady * 2 + 56
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    # title bar
    d.rectangle([0, 0, W, 46], fill=TITLEBAR)
    for i, c in enumerate([(255,95,86), (255,189,46), (39,201,63)]):
        d.ellipse([14 + i*24, 14, 30 + i*24, 30], fill=c)
    d.text((96, 4), title, font=font, fill=TITLEFG)

    y = 46 + pady
    for line in lines:
        if line.startswith("$ "):
            d.text((padx, y), "$", font=font, fill=PROMPT)
            d.text((padx + mono_w, y), line[2:], font=font, fill=CMD)
        else:
            col = pick_color(line)
            d.text((padx, y), line, font=font, fill=col or FG)
        y += lh

    img.save(outp)
    print(f"wrote {outp} {W}x{H}")

if __name__ == "__main__":
    main()
