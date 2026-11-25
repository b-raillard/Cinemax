"""« Givre » — the frost texture of the Christmas season.

Writes `SeasonFrost.imageset`: one TILEABLE frost texture (white needles in
small feathered clusters + a fine ice speckle, on transparency). The app tiles
it and masks it — into the four corners of the screen (`SeasonalFrostCorners`)
and the edges of the heroes (`SeasonalHeroFrost`); the haze under it is drawn
in SwiftUI. Proportions follow the artifact « Noël JellyGlass », theme Givre,
chosen by the owner on 2026-11-20.

    python3 design/noel/givre.py

Fixed seeds: the output is reproducible. Never hand-edit the PNGs.
"""
import json
import math
import os
import random

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FOLDER = os.path.join(ROOT, "Resources/Assets.xcassets/SeasonFrost.imageset")

# (idiom, scale, tile side in points, needle length range in points, line width in points,
#  feather clusters per tile, speckles per tile)
VARIANTS = [
    ("universal", 2, 400, (2.0, 7.0), 0.45, 190, 4100),
    ("universal", 3, 400, (2.0, 7.0), 0.45, 190, 4100),
    ("tv", 1, 900, (4.0, 14.0), 1.0, 170, 3500),
    ("tv", 2, 900, (4.0, 14.0), 1.0, 170, 3500),
]
SUPER = 2   # drawn at twice the size, then downsampled: antialiased needles


def texture(scale, side_pt, needle, width_pt, clusters, speckles, seed=7):
    px = side_pt * scale * SUPER
    k = scale * SUPER            # pixels per point on the drawing canvas
    rnd = random.Random(seed)
    alpha = Image.new("L", (px, px), 0)
    d = ImageDraw.Draw(alpha)

    def line(x0, y0, x1, y1, a, w):
        # Drawn nine times, shifted by one tile, so the texture wraps seamlessly.
        for dx in (-px, 0, px):
            for dy in (-px, 0, px):
                d.line([x0 + dx, y0 + dy, x1 + dx, y1 + dy], fill=a, width=w)

    for _ in range(clusters):
        x, y = rnd.uniform(0, px), rnd.uniform(0, px)
        ang = rnd.uniform(0, 2 * math.pi)
        length = rnd.uniform(*needle) * k
        a = int(255 * rnd.uniform(0.28, 0.62))
        w = max(1, round(width_pt * k * rnd.uniform(0.8, 1.6)))
        for _seg in range(3):
            ex, ey = x + math.cos(ang) * length, y + math.sin(ang) * length
            line(x, y, ex, ey, a, w)
            # barbs at 60°, shorter toward the tip: an ice feather
            for b in range(1, 5):
                t = b / 5
                bx, by = x + (ex - x) * t, y + (ey - y) * t
                bl = length * (0.45 - t * 0.3)
                for sg in (-1, 1):
                    ba = ang + sg * math.pi / 3
                    line(bx, by, bx + math.cos(ba) * bl, by + math.sin(ba) * bl, int(a * 0.85), max(1, w - 1))
            x, y = ex, ey
            ang += rnd.uniform(-0.3, 0.3)
            length *= 0.75

    for _ in range(speckles):
        x, y = rnd.uniform(0, px), rnd.uniform(0, px)
        r = rnd.uniform(0.15, 0.65) * k
        d.ellipse([x - r, y - r, x + r, y + r], fill=int(255 * rnd.uniform(0.1, 0.55)))

    side = side_pt * scale
    alpha = alpha.resize((side, side), Image.LANCZOS)
    img = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


def main():
    os.makedirs(FOLDER, exist_ok=True)
    images = []
    for idiom, scale, side, needle, width, clusters, speckles in VARIANTS:
        name = f"seasonfrost_{idiom}@{scale}x.png"
        texture(scale, side, needle, width, clusters, speckles).save(os.path.join(FOLDER, name), optimize=True)
        images.append({"filename": name, "idiom": idiom, "scale": f"{scale}x"})
        print(name)
    with open(os.path.join(FOLDER, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
