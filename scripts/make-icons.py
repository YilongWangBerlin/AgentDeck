#!/usr/bin/env python3
"""Turns the two generated source images in Packaging/ into the app icon (.icns) and the menu bar
template image. Run after replacing a source image."""
from pathlib import Path
import subprocess, tempfile
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent / "Packaging"

# --- App icon: cut the squircle out of its white surround and place it on Apple's 1024 grid.
src = Image.open(root / "AppIcon-source.png").convert("RGB")
w, h = src.size
# Walking inward, the surround darkens through the tile's soft shadow and then brightens sharply
# where the tile starts. That jump is the edge.
def edge(points):
    previous = None
    for index, point in enumerate(points):
        brightness = sum(src.getpixel(point))
        if previous is not None and brightness - previous > 15:
            return index
        previous = brightness
    raise SystemExit("could not find the tile edge")
left = edge([(x, h // 2) for x in range(w)])
right = w - edge([(w - 1 - x, h // 2) for x in range(w)])
top = edge([(w // 2, y) for y in range(h)])
size = right - left
tile = src.crop((left, top, left + size, top + size)).convert("RGBA")
mask = Image.new("L", (size * 4, size * 4), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * 0.225), fill=255)
tile.putalpha(mask.resize((size, size), Image.LANCZOS))
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
canvas.alpha_composite(tile.resize((824, 824), Image.LANCZOS), (100, 100))
canvas.save(root / "AppIcon-1024.png")

with tempfile.TemporaryDirectory() as tmp:
    iconset = Path(tmp) / "AppIcon.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            canvas.resize((px, px), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "AppIcon.icns")], check=True)

# --- Menu bar: black ink becomes opaque, white becomes transparent; cropped and padded square.
glyph = Image.open(root / "MenuBarIcon-source.png").convert("L")
alpha = glyph.point(lambda v: 255 - v)
alpha = alpha.point(lambda v: 0 if v < 24 else v)
left, top, right, bottom = alpha.getbbox()
side = max(right - left, bottom - top)
side = int(side * 1.06)
cx, cy = (left + right) // 2, (top + bottom) // 2
alpha = alpha.crop((cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side))
ink = Image.new("RGBA", alpha.size, (0, 0, 0, 255))
ink.putalpha(alpha)
for scale, suffix in ((1, ""), (2, "@2x")):
    ink.resize((18 * scale, 18 * scale), Image.LANCZOS).save(root / f"MenuBarIcon{suffix}.png")

print("wrote AppIcon.icns, AppIcon-1024.png, MenuBarIcon.png, MenuBarIcon@2x.png")
