#!/usr/bin/env python3
"""Regenerate AgentMeter's app icon (AppIcon.icns) and the DMG background.

Run from anywhere; writes AppIcon.icns + dmg-background.tiff next to this script.
Requires: Pillow, numpy, and macOS `iconutil`. Deps: `pip install pillow numpy`.
"""
import math
import os
import struct
import subprocess
import tempfile
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))
SF = "/System/Library/Fonts/SFNS.ttf"
SFROUND = "/System/Library/Fonts/SFCompactRounded.ttf"

def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def sf(size, weight="Regular"):
    f = ImageFont.truetype(SF, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i]-a[i])*t)) for i in range(3))

# ----------------------------------------------------------------------------
# App icon: a speedometer-style gauge on a dark squircle, value arc colored
# green->amber (echoing the app's quota threshold scale), with a white needle.
# ----------------------------------------------------------------------------
def make_icon(px=1024):
    S = px * 4  # supersample
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # --- squircle mask + vertical gradient fill ---
    margin = int(S * 0.085)
    side = S - 2 * margin
    n = 5.0  # superellipse exponent (Apple-ish continuous corner)
    yy, xx = np.mgrid[0:side, 0:side].astype(np.float64)
    cx = cy = (side - 1) / 2.0
    nx = (xx - cx) / (side / 2.0)
    ny = (yy - cy) / (side / 2.0)
    inside = (np.abs(nx)**n + np.abs(ny)**n) <= 1.0
    # smooth edge
    d = (np.abs(nx)**n + np.abs(ny)**n)
    alpha = np.clip((1.02 - d) / 0.04, 0, 1)

    top, bot = hex2rgb("#2C3550"), hex2rgb("#141A2A")
    grad = np.zeros((side, side, 4), dtype=np.uint8)
    for row in range(side):
        t = row / (side - 1)
        c = lerp(top, bot, t)
        grad[row, :, 0] = c[0]; grad[row, :, 1] = c[1]; grad[row, :, 2] = c[2]
    grad[:, :, 3] = (alpha * 255).astype(np.uint8)
    sq = Image.fromarray(grad, "RGBA")
    img.paste(sq, (margin, margin), sq)

    # subtle top sheen
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.ellipse([margin-S*0.1, margin-S*0.45, S-margin+S*0.1, margin+side*0.55],
               fill=(255, 255, 255, 26))
    sheen = sheen.filter(ImageFilter.GaussianBlur(S*0.02))
    sqmask = Image.fromarray((alpha*255).astype(np.uint8), "L")
    full_mask = Image.new("L", (S, S), 0)
    full_mask.paste(sqmask, (margin, margin))
    img = Image.composite(Image.alpha_composite(img, sheen), img, full_mask)

    d = ImageDraw.Draw(img)
    cxp = cyp = S // 2
    R = int(side * 0.34)
    width = int(side * 0.085)

    start, total = 135.0, 270.0   # gap at bottom
    value = 0.70

    # track
    d.arc([cxp-R, cyp-R, cxp+R, cyp+R], start, start+total,
          fill=(255, 255, 255, 38), width=width)

    # value arc, green -> amber along its length
    g, a = hex2rgb("#22C55E"), hex2rgb("#F59E0B")
    steps = 90
    end = start + total * value
    seg = (end - start) / steps
    for i in range(steps):
        s0 = start + i * seg
        c = lerp(g, a, i / (steps - 1))
        d.arc([cxp-R, cyp-R, cxp+R, cyp+R], s0, s0 + seg + 0.6,
              fill=c + (255,), width=width)
    # rounded caps on the value arc
    for ang, c in ((start, g), (end, a)):
        rad = math.radians(ang)
        ex, ey = cxp + R*math.cos(rad), cyp + R*math.sin(rad)
        d.ellipse([ex-width/2, ey-width/2, ex+width/2, ey+width/2], fill=c+(255,))

    # tick marks
    for i in range(7):
        ang = math.radians(start + total * i / 6)
        r1, r2 = R + width*0.75, R + width*1.25
        x1, y1 = cxp + r1*math.cos(ang), cyp + r1*math.sin(ang)
        x2, y2 = cxp + r2*math.cos(ang), cyp + r2*math.sin(ang)
        d.line([x1, y1, x2, y2], fill=(255, 255, 255, 70), width=int(width*0.16))

    # needle pointing at value
    nang = math.radians(end)
    nlen = R * 0.96
    tip = (cxp + nlen*math.cos(nang), cyp + nlen*math.sin(nang))
    perp = nang + math.pi/2
    bw = width * 0.42
    base1 = (cxp + bw*math.cos(perp), cyp + bw*math.sin(perp))
    base2 = (cxp - bw*math.cos(perp), cyp - bw*math.sin(perp))
    back = (cxp - nlen*0.18*math.cos(nang), cyp - nlen*0.18*math.sin(nang))
    d.polygon([tip, base1, back, base2], fill=(255, 255, 255, 255))
    # hub
    hub = width * 0.75
    d.ellipse([cxp-hub, cyp-hub, cxp+hub, cyp+hub], fill=(255, 255, 255, 255))
    d.ellipse([cxp-hub*0.45, cyp-hub*0.45, cxp+hub*0.45, cyp+hub*0.45],
              fill=hex2rgb("#1B2235") + (255,))

    master = img.resize((px, px), Image.LANCZOS)
    return master

# ----------------------------------------------------------------------------
# DMG background for a 600x400 install window. Title + tagline on top, a clear
# arrow between the two icon slots, an install hint at the bottom. Rendered at a
# given integer scale so we can emit a 1x + 2x HiDPI TIFF (Finder shows the
# background at native pixels, so the file must match the window point size).
# Icon centers sit at window points (150, 235) and (450, 235) — keep dmg-settings
# icon_locations in sync.
# ----------------------------------------------------------------------------
def make_dmg_bg(scale=2):
    s = scale
    W, H = 600 * s, 400 * s
    arr = np.zeros((H, W, 3), dtype=np.uint8)
    t0, t1 = hex2rgb("#FCFCFE"), hex2rgb("#ECECF0")
    for row in range(H):
        arr[row, :] = lerp(t0, t1, row / (H - 1))
    img = Image.fromarray(arr, "RGB")
    d = ImageDraw.Draw(img)

    def ctext(txt, cy, font, color):
        b = d.textbbox((0, 0), txt, font=font)
        w, h = b[2] - b[0], b[3] - b[1]
        d.text(((W - w) // 2 - b[0], cy - h // 2 - b[1]), txt, font=font, fill=color)

    ctext("AgentMeter", 58 * s, sf(30 * s, "Bold"), hex2rgb("#1D1D1F"))
    ctext("Codex & Claude usage at a glance", 100 * s,
          sf(15 * s, "Regular"), hex2rgb("#86868B"))

    # arrow between the icon slots (icon centers at x=150 / x=450, y=235)
    ay = 235 * s
    col = hex2rgb("#A1A1A8")
    th = 7 * s
    x1, x2 = 262 * s, 338 * s
    d.line([x1, ay, x2 - 12 * s, ay], fill=col, width=th)
    hh = 15 * s
    d.polygon([(x2, ay), (x2 - 19 * s, ay - hh), (x2 - 19 * s, ay + hh)], fill=col)

    ctext("Drag the app onto the Applications folder", 360 * s,
          sf(15 * s, "Regular"), hex2rgb("#6E6E73"))
    return img

def build_dmg_bg():
    """Write dmg-background.tiff with a 600x400 @72dpi base + 1200x800 @144dpi HiDPI
    rep. The 144dpi tag is essential: without it macOS treats the 2x image as a
    1200x800-point background, oversizing the window content and adding a scrollbar."""
    p1, p2 = f"{OUT}/.bg1.png", f"{OUT}/.bg2.png"
    make_dmg_bg(1).save(p1, dpi=(72, 72))
    make_dmg_bg(2).save(p2, dpi=(144, 144))
    subprocess.run(["tiffutil", "-cathidpicheck", p1, p2,
                    "-out", f"{OUT}/dmg-background.tiff"], check=True)
    os.remove(p1)
    os.remove(p2)

def write_png_icns(master, out_path):
    """Write a PNG-backed .icns file directly when iconutil is unavailable."""
    entries = [(16, b"icp4"), (32, b"icp5"), (64, b"icp6"), (128, b"ic07"),
               (256, b"ic08"), (512, b"ic09"), (1024, b"ic10")]
    chunks = []
    for px, kind in entries:
        with tempfile.NamedTemporaryFile(suffix=".png") as png:
            master.resize((px, px), Image.LANCZOS).save(png.name, dpi=(72, 72))
            data = open(png.name, "rb").read()
        chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
    with open(out_path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + sum(len(c) for c in chunks)))
        for chunk in chunks:
            f.write(chunk)

def build_icns(master):
    """Master 1024 PNG -> AppIcon.icns via a temporary .iconset + iconutil."""
    sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
             (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
             (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for px, name in sizes:
            master.resize((px, px), Image.LANCZOS).save(f"{iconset}/icon_{name}.png")
        out_path = f"{OUT}/AppIcon.icns"
        try:
            subprocess.run(["iconutil", "-c", "icns", iconset,
                            "-o", out_path], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (FileNotFoundError, subprocess.CalledProcessError):
            write_png_icns(master, out_path)

if __name__ == "__main__":
    build_icns(make_icon(1024))
    build_dmg_bg()
    print(f"wrote {OUT}/AppIcon.icns and {OUT}/dmg-background.tiff")
