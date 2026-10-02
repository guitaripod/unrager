#!/usr/bin/env python3
"""Test charts for the media lab (`mock_server.py --lab`): one image per
aspect ratio, drawn so that any crop shows at once, as a cut corner marker,
a missing edge tick or a clipped label. Writes assets/photos/lab_<W>x<H>[_<k>].jpg
and, for the clips, assets/videos/vlab_<W>x<H>.{jpg,mp4} (poster and a 3 s
loop made with ffmpeg).

    python3 make_lab.py
"""
import colorsys
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
PHOTOS = HERE / "assets" / "photos"
VIDEOS = HERE / "assets" / "videos"

SIZES = [
    (1080, 1080), (1600, 1200), (1620, 1080), (1920, 1080), (2100, 900), (3000, 1000), (3000, 600),
    (1080, 1350), (1200, 1600), (1000, 1500), (1080, 1920), (900, 1800), (1000, 3000), (600, 3000),
    (200, 150), (1200, 628),
]
VARIANTS = "abcde"
VIDEO_SIZES = [(1280, 720), (720, 1280), (720, 720), (864, 1080), (1260, 540)]

FONT_PATHS = ["/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"]


def font(size):
    for path in FONT_PATHS:
        if Path(path).exists():
            return ImageFont.truetype(path, max(8, int(size)))
    return ImageFont.load_default()


def ratio_label(w, h):
    g = math.gcd(w, h)
    a, b = w // g, h // g
    return f"{a}:{b}" if a <= 40 and b <= 40 else f"{w / h:.2f}:1"


def chart(w, h, tag=""):
    hue = (w * 7 + h * 13) % 360 / 360
    top = tuple(int(c * 255) for c in colorsys.hsv_to_rgb(hue, 0.55, 0.95))
    bottom = tuple(int(c * 255) for c in colorsys.hsv_to_rgb((hue + 0.12) % 1, 0.7, 0.45))
    img = Image.new("RGB", (w, h))
    px = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        px.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    m = min(w, h)
    line = max(2, m // 180)
    for k in range(1, 10):
        x, y = w * k / 10, h * k / 10
        px.line([(x, 0), (x, h)], fill=(255, 255, 255), width=1)
        px.line([(0, y), (w, y)], fill=(255, 255, 255), width=1)
        tick = m * (0.05 if k == 5 else 0.025)
        for edge in (0, w - 1):
            px.line([(edge - tick if edge else 0, y), (edge if edge else tick, y)], fill=(0, 0, 0), width=line)
        for edge in (0, h - 1):
            px.line([(x, edge - tick if edge else 0), (x, edge if edge else tick)], fill=(0, 0, 0), width=line)
    px.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255), width=line * 2)
    inset = m * 0.06
    px.rectangle([inset, inset, w - inset, h - inset], outline=(255, 0, 170), width=line)
    corner = m * 0.16
    for (cx, cy, col, dx, dy) in [(0, 0, (230, 40, 40), 1, 1), (w, 0, (40, 190, 70), -1, 1),
                                  (0, h, (50, 90, 235), 1, -1), (w, h, (250, 210, 30), -1, -1)]:
        px.polygon([(cx, cy), (cx + dx * corner, cy), (cx, cy + dy * corner)], fill=col)
    radius = m * 0.28
    px.ellipse([w / 2 - radius, h / 2 - radius, w / 2 + radius, h / 2 + radius], outline=(255, 255, 255), width=line * 2)
    px.line([(w / 2 - radius, h / 2), (w / 2 + radius, h / 2)], fill=(255, 255, 255), width=line)
    px.line([(w / 2, h / 2 - radius), (w / 2, h / 2 + radius)], fill=(255, 255, 255), width=line)
    fx, fy, fr = w / 2, h * 0.2 if h > w else h * 0.3, m * 0.07
    px.ellipse([fx - fr, fy - fr, fx + fr, fy + fr], fill=(255, 224, 160), outline=(0, 0, 0), width=max(1, line // 2))
    for dx in (-0.35, 0.35):
        px.ellipse([fx + dx * fr * 1.2 - fr * 0.12, fy - fr * 0.25 - fr * 0.12, fx + dx * fr * 1.2 + fr * 0.12, fy - fr * 0.25 + fr * 0.12], fill=(0, 0, 0))
    px.arc([fx - fr * 0.55, fy - fr * 0.1, fx + fr * 0.55, fy + fr * 0.55], 20, 160, fill=(0, 0, 0), width=max(1, line // 2))
    big, small = font(m * 0.13), font(m * 0.07)
    label = f"{w}×{h}"
    px.text((w / 2, h / 2 + radius + m * 0.02), label, font=big, fill=(255, 255, 255), anchor="ma", stroke_width=max(1, line // 2), stroke_fill=(0, 0, 0))
    px.text((w / 2, h / 2 - radius - m * 0.02), f"{ratio_label(w, h)} {tag}".strip(), font=big, fill=(255, 255, 255), anchor="ms", stroke_width=max(1, line // 2), stroke_fill=(0, 0, 0))
    px.text((m * 0.07, h / 2), "L", font=small, fill=(255, 255, 255), anchor="lm", stroke_width=1, stroke_fill=(0, 0, 0))
    px.text((w - m * 0.07, h / 2), "R", font=small, fill=(255, 255, 255), anchor="rm", stroke_width=1, stroke_fill=(0, 0, 0))
    return img


def main():
    PHOTOS.mkdir(parents=True, exist_ok=True)
    VIDEOS.mkdir(parents=True, exist_ok=True)
    for w, h in SIZES:
        chart(w, h).save(PHOTOS / f"lab_{w}x{h}.jpg", quality=88)
        for variant in VARIANTS:
            chart(w, h, variant.upper()).save(PHOTOS / f"lab_{w}x{h}_{variant}.jpg", quality=88)
    for w, h in VIDEO_SIZES:
        chart(w, h, "video").save(VIDEOS / f"vlab_{w}x{h}.jpg", quality=88)
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={w}x{h}:rate=30",
                        "-t", "3", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(VIDEOS / f"vlab_{w}x{h}.mp4")], check=True)
    print("lab charts:", len(list(PHOTOS.glob("lab_*"))), "photos,", len(list(VIDEOS.glob("vlab_*.mp4"))), "clips")


if __name__ == "__main__":
    sys.exit(main())
