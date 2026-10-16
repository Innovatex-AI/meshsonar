#!/usr/bin/env python3
"""Draws the MeshSonar app icon (1024x1024 PNG) from scratch: sonar arcs pinging out from a dot to three repeaters,
on a deep teal background. Also writes a transparent foreground for Android adaptive icons.

    python3 tool/make_icon.py        # writes assets/icon/*.png
Then: dart run flutter_launcher_icons
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersampling
BG_TOP = (14, 77, 79)
BG_BOTTOM = (6, 42, 44)
GLOW = (60, 232, 200)
PING = (255, 200, 87)
OUT = os.path.join(os.path.dirname(__file__), '..', 'assets', 'icon')


def gradient(size):
    img = Image.new('RGB', (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
        d.line([(0, y), (size, y)], fill=c)
    return img


def art(size, scale=1.0):
    """The sonar mark on a transparent layer. scale<1 shrinks it toward the centre (adaptive-icon safe zone)."""
    W = size * SS
    layer = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = W * 0.5, W * (0.5 + 0.09 * scale)
    R = W * 0.40 * scale

    # soft glow disc
    glow = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([cx - R * 1.05, cy - R * 1.05, cx + R * 1.05, cy + R * 1.05], fill=GLOW + (46,))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.06))
    layer.alpha_composite(glow)

    # faint full radar rings
    for frac in (0.36, 0.66, 0.96, 1.26):
        r = R * frac
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=GLOW + (34,), width=max(2, int(W * 0.006 * scale)))

    # arcs: 210..330 degrees (opening upward)
    width = int(W * 0.04 * scale)
    for i, (frac, alpha) in enumerate([(0.36, 255), (0.66, 215), (0.96, 165)]):
        r = R * frac + width / 2  # PIL draws the stroke inside the box; centre it on r
        bbox = [cx - r, cy - r, cx + r, cy + r]
        d.arc(bbox, start=215, end=325, fill=GLOW + (alpha,), width=width)
        # rounded caps, on the stroke centre line
        for ang in (215, 325):
            a = math.radians(ang)
            rc = r - width / 2
            px, py = cx + rc * math.cos(a), cy + rc * math.sin(a)
            d.ellipse([px - width / 2, py - width / 2, px + width / 2, py + width / 2], fill=GLOW + (alpha,))

    # repeaters (small towers with a lit head) out on the outer ring
    for ang, lit in ((228, True), (270, False), (312, True)):
        a = math.radians(ang)
        rr = R * 1.18
        px, py = cx + rr * math.cos(a), cy + rr * math.sin(a)
        s = W * 0.045 * scale
        col = PING + (255,) if lit else (230, 245, 242, 210)
        lw = int(s * 0.32)
        d.line([(px, py - s * 0.15), (px - s * 0.62, py + s * 1.05)], fill=col, width=lw)
        d.line([(px, py - s * 0.15), (px + s * 0.62, py + s * 1.05)], fill=col, width=lw)
        d.ellipse([px - s * 0.38, py - s * 0.85, px + s * 0.38, py - s * 0.09], fill=col)

    # the ping
    pr = W * 0.06 * scale
    ring = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse([cx - pr * 2.0, cy - pr * 2.0, cx + pr * 2.0, cy + pr * 2.0], fill=PING + (90,))
    ring = ring.filter(ImageFilter.GaussianBlur(W * 0.02))
    layer.alpha_composite(ring)
    d = ImageDraw.Draw(layer)
    d.ellipse([cx - pr, cy - pr, cx + pr, cy + pr], fill=PING + (255,))
    return layer.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    bg = gradient(S).convert('RGBA')
    icon = bg.copy()
    icon.alpha_composite(art(S))
    icon.convert('RGB').save(os.path.join(OUT, 'icon.png'))  # iOS wants no alpha
    art(S, scale=0.68).save(os.path.join(OUT, 'foreground.png'))
    # Launch-screen mark: same art on transparent, small.
    art(512, scale=1.0).save(os.path.join(OUT, 'launch_mark.png'))
    print('wrote', os.path.abspath(OUT))


if __name__ == '__main__':
    main()
