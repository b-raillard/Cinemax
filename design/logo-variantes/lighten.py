#!/usr/bin/env python3
"""Make the iOS 1024 icons cheap to ship without a visible change.

    python3 design/logo-variantes/lighten.py

actool does not keep the PNG: it stores every 1024² icon as raw ARGB (Gray for
the tinted one) compressed with lzfse. The icons' ground carries a fine grain
(neighbouring pixels differ by 1–2 levels), so lzfse finds almost no repeats and
each image costs ~1.4 MB in `Assets.car` — 13 icon sets, 39.6 MB (audit M-01,
2026-11-13). A lossless PNG re-compression changes nothing there.

The fix pulls every pixel towards a soft blur of the image (Gaussian, radius
`RADIUS`) by at most `MAX_STEP` levels per channel. In the ground the grain
fits inside that budget, so it becomes a smooth surface with long runs of equal
pixels; on the jellyfish's lines the blur is far away and the pixel moves by
`MAX_STEP` at most. No pixel of any channel moves by more than 2 levels out of
255 (PSNR ≈ 47 dB): lossy, but not visible — the comparison of 2026-11-13 is in
the audit's `icons-compare.png`.

Idempotent: a processed PNG carries the text chunk `LIGHTENED` and is skipped,
so running it twice (or after `recolor.py --alternates`, which copies files
AS-IS) never moves a pixel a second time. Size, mode (RGB, no alpha) and the
absence of an ICC profile are kept.

Sweeps the iOS icons in Resources/ (primary + every alternate) and in
declinaisons/ (what `recolor.py --alternates` and `scripts/seasonal-icon.py`
copy from). `recolor.py` calls it at the end of each run. tvOS layers are NOT
touched (recolor.py compares them pixel for pixel with declinaisons/classique).
"""
import glob
import os

import numpy as np
from PIL import Image, ImageFilter, PngImagePlugin

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(ROOT, "Resources/Assets.xcassets")
OUT = os.path.join(HERE, "declinaisons")

RADIUS = 6       # px at 1024
MAX_STEP = 2     # levels per channel, out of 255
MARKER = "LIGHTENED"
MARKER_VALUE = f"gaussian {RADIUS} px, at most {MAX_STEP} levels per channel"


def lighten_array(rgb):
    """uint8 H×W×3 → uint8 H×W×3, each channel within ±MAX_STEP of the input."""
    blurred = np.asarray(Image.fromarray(rgb).filter(ImageFilter.GaussianBlur(RADIUS))).astype(np.float32)
    src = rgb.astype(np.float32)
    out = np.rint(src + np.clip(blurred - src, -MAX_STEP, MAX_STEP))
    return np.clip(out, 0, 255).astype(np.uint8)


def lighten_file(path):
    """Returns True when the file was rewritten, False when already done."""
    img = Image.open(path)
    if MARKER in getattr(img, "text", {}):
        return False
    if img.mode != "RGB" or img.size != (1024, 1024) or img.info.get("icc_profile"):
        raise SystemExit(f"{path}: expected a 1024² RGB PNG without ICC profile, got {img.size} {img.mode}")
    rgb = np.asarray(img)
    out = lighten_array(rgb)
    assert np.abs(out.astype(int) - rgb).max() <= MAX_STEP
    info = PngImagePlugin.PngInfo()
    info.add_text(MARKER, MARKER_VALUE)
    Image.fromarray(out).save(path, optimize=True, pnginfo=info)
    return True


def targets():
    paths = glob.glob(os.path.join(ASSETS, "*.appiconset", "app_icon_1024*.png"))
    paths += glob.glob(os.path.join(OUT, "*", "AppIcon.appiconset", "app_icon_1024*.png"))
    return sorted(paths)


def main():
    changed = [p for p in targets() if lighten_file(p)]
    for p in changed:
        print(f"lightened  {os.path.relpath(p, ROOT)}")
    print(f"{len(changed)} icon(s) lightened, {len(targets()) - len(changed)} already done")


if __name__ == "__main__":
    main()
